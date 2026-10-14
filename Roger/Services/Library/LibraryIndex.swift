import CoreServices
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryIndex")

/// Everything the library window lists, kept current while Roger runs. An
/// in-memory implementation today; a SQLite FTS5 one can replace it behind
/// this protocol if libraries ever grow far beyond a few thousand items.
protocol LibraryIndex: Sendable {
    /// All items, newest first.
    func items() async -> [LibraryItem]
    func search(_ query: LibraryQuery) async -> [LibraryItem]
    /// Yields after the first build and after every change to the items.
    /// Single consumer: iterate it from one place only (it is one
    /// `AsyncStream`, not a broadcast). Finishes when the index is released.
    var changes: AsyncStream<Void> { get }
    /// True when the library root is not a folder (deleted, or on a drive
    /// that is not connected).
    func libraryRootMissing() async -> Bool
    /// Looks at the root again; reads everything again when it appeared or
    /// went away.
    func recheckRoot() async
    /// Reads these files again now, without waiting for the folder watcher
    /// (after Roger wrote them).
    func refresh(paths: [String]) async
    /// What changed since the last call, then starts over. Read it after
    /// `changes` yielded.
    func takeChange() async -> LibraryIndexChange
}

extension LibraryIndex {
    func libraryRootMissing() async -> Bool { false }
    func recheckRoot() async {}
    func refresh(paths: [String]) async {}
    func takeChange() async -> LibraryIndexChange {
        LibraryIndexChange(itemsChanged: true, sessionFolders: [])
    }
}

/// What must be read again after a file system change. Paths are canonical.
enum LibraryScanUnit: Hashable, Sendable {
    /// One Markdown file; the kind is the fallback when its tags do not say.
    case file(String, LibraryItemKind)
    /// One meeting session folder.
    case session(String)
    /// A folder below Logs, Meetings or Transcripts, with everything inside.
    case tree(String, LibraryItemKind)
    /// An extra scan folder itself.
    case extraFolder(String)
    /// The external-transcripts list changed.
    case externalList
    /// The library root or one of its parents changed.
    case everything
}

/// What changed in an index since the last `takeChange()`.
struct LibraryIndexChange: Equatable, Sendable {
    /// The items changed or were read again: the list must reload.
    var itemsChanged: Bool
    /// Canonical paths of the meeting session folders something changed in,
    /// also when their meeting item stayed the same.
    var sessionFolders: Set<String>
}

/// Scans `Logs/`, `Meetings/`, `Transcripts/`, the extra scan folders and
/// the external-transcripts list. Built on first use. Keeps one item per
/// canonical path. Meetings come only from session folders and only as
/// their `transcript.md`, so `transcript.previous*.md` and segment files are
/// never listed.
actor InMemoryLibraryIndex: LibraryIndex {
    nonisolated let scope: LibraryScanScope
    nonisolated let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let externalFiles: @Sendable () -> [URL]
    private let externalListPath: String?
    private let root: String
    private let logs: String
    private let meetings: String
    private let transcripts: String
    private let extras: [String]
    private var itemsByID: [String: LibraryItem] = [:]
    private var externalIDs: Set<String> = []
    private var isBuilt = false
    /// How often `changes` yielded. For tests: a missing yield would make
    /// them wait forever on the stream.
    private(set) var changeCount = 0
    /// Collected for `takeChange()`.
    private var pendingItemsChanged = false
    private var pendingSessionFolders: Set<String> = []
    /// Set by every full build: the root is not a folder.
    private var rootMissing = false
    private let watchesFileSystem: Bool
    private var watcher: LibraryFolderWatcher?
    private var eventTask: Task<Void, Never>?
    private var eventSink: AsyncStream<[String]?>.Continuation?
    /// Set by `stopWatching()`; a stopped index never watches again.
    private(set) var watchingStopped = false
    /// The FSEvents id taken before the latest scan, so a restarted stream
    /// replays what changed during that scan.
    private var scanEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    /// `externalFiles` lists transcripts written next to their source
    /// (`ExternalTranscriptRegistry.existingFiles`). `externalListURL` is the
    /// file that list is stored in; a change to it re-reads the list.
    init(
        scope: LibraryScanScope,
        externalFiles: @escaping @Sendable () -> [URL],
        externalListURL: URL? = nil,
        watchesFileSystem: Bool = false
    ) {
        self.watchesFileSystem = watchesFileSystem
        self.scope = scope
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.changes = stream
        self.continuation = continuation
        self.externalFiles = externalFiles
        self.externalListPath = externalListURL.map { LibraryPath.canonical($0) }
        self.root = LibraryPath.canonical(scope.layout.root)
        self.logs = LibraryPath.canonical(scope.layout.kindFolder(.logs))
        self.meetings = LibraryPath.canonical(scope.layout.kindFolder(.meetings))
        self.transcripts = LibraryPath.canonical(scope.layout.kindFolder(.transcripts))
        self.extras = scope.extraFolders.map { LibraryPath.canonical($0) }
    }

    deinit {
        eventTask?.cancel()
        continuation.finish()
    }

    func items() async -> [LibraryItem] {
        buildIfNeeded()
        return LibraryQuery.sorted(Array(itemsByID.values), by: .newestFirst)
    }

    func search(_ query: LibraryQuery) async -> [LibraryItem] {
        buildIfNeeded()
        return query.apply(to: Array(itemsByID.values))
    }

    /// Reads everything again.
    func rebuild() {
        let start = Date()
        scanEventId = FSEventsGetCurrentEventId()
        rootMissing = !Self.isFolder(root)
        itemsByID = scanAll()
        isBuilt = true
        // Plain locals: Logger interpolation must not touch actor state.
        let count = itemsByID.count
        let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("Library index built: \(count) items in \(milliseconds) ms")
        pendingItemsChanged = true
        notifyChange()
        if watchesFileSystem { restartWatcherIfNeeded() }
    }

    func refresh(paths: [String]) async {
        apply(changedPaths: paths)
    }

    /// Reads again what `paths` touched. Paths may be spelled as FSEvents
    /// reports them or not. Does nothing before the first build.
    func apply(changedPaths paths: [String]) {
        guard isBuilt else { return }
        let known = Self.meetingFolders(itemsByID)
        let units = Set(paths.compactMap { unit(forChangedPath: $0, knownMeetings: known) })
        guard !units.isEmpty else { return }
        if units.contains(.everything) {
            rebuild()
            return
        }
        let before = itemsByID
        scanEventId = FSEventsGetCurrentEventId()
        for unit in units { reload(unit) }
        // A change inside a meeting folder is reported even when the meeting
        // item stayed the same: the Extra files section lists the folder again.
        let sessions = units.compactMap { unit -> String? in
            if case .session(let folder) = unit { return folder } else { return nil }
        }
        let itemsChanged = itemsByID != before
        if itemsChanged { pendingItemsChanged = true }
        pendingSessionFolders.formUnion(sessions)
        if itemsChanged || !sessions.isEmpty { notifyChange() }
    }

    func takeChange() async -> LibraryIndexChange {
        defer {
            pendingItemsChanged = false
            pendingSessionFolders = []
        }
        return LibraryIndexChange(itemsChanged: pendingItemsChanged, sessionFolders: pendingSessionFolders)
    }

    private func notifyChange() {
        changeCount += 1
        continuation.yield()
    }

    /// Maps one changed path to what must be read again. Nil for paths
    /// outside the library and for hidden files and folders below a kind
    /// folder or an extra folder (the full scan skips them too).
    func unit(forChangedPath raw: String, knownMeetings: Set<String>? = nil) -> LibraryScanUnit? {
        let path = LibraryPath.canonical(URL(fileURLWithPath: raw))
        if let list = externalListPath, path == list { return .externalList }
        if externalIDs.contains(path) { return .file(path, .transcript) }
        if LibraryPath.isPath(root, inside: path) { return .everything }
        for (folder, kind) in [(logs, LibraryItemKind.log), (transcripts, .transcript)]
        where LibraryPath.isPath(path, inside: folder) {
            guard !Self.hasHiddenPart(path, below: folder) else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "md" { return .file(path, kind) }
            // Audio next to a log entry: its .md says whether it has audio.
            if ext == "m4a" { return .file((path as NSString).deletingPathExtension + ".md", kind) }
            return ext.isEmpty ? .tree(path, kind) : nil
        }
        if LibraryPath.isPath(path, inside: meetings) {
            guard !Self.hasHiddenPart(path, below: meetings) else { return nil }
            // Sessions sit up to three levels down (`YYYY/MM/<session>` or
            // anywhere above), like the full scan finds them.
            return sessionFolder(containing: path, below: meetings, maxDepth: 3, known: knownMeetings).map(LibraryScanUnit.session)
                ?? .tree(path, .meeting)
        }
        for extra in extras where LibraryPath.isPath(path, inside: extra) {
            guard !Self.hasHiddenPart(path, below: extra) else { return nil }
            let parts = LibraryPath.components(of: path, below: extra)
            guard let first = parts.first else { return .extraFolder(extra) }
            if parts.count == 1 {
                let ext = (first as NSString).pathExtension.lowercased()
                if ext == "md" { return .file(path, .transcript) }
                if !ext.isEmpty { return nil }
            }
            // Sessions sit directly in an extra folder.
            return .session(extra + "/" + first)
        }
        return nil
    }

    private static func meetingFolders(_ items: [String: LibraryItem]) -> Set<String> {
        Set(items.values.filter { $0.kind == .meeting }.map(\.folderURL.path))
    }

    /// True when a part of `path` below `folder` starts with a dot.
    private static func hasHiddenPart(_ path: String, below folder: String) -> Bool {
        LibraryPath.components(of: path, below: folder).contains { $0.hasPrefix(".") }
    }

    /// The session folder that holds `path` (or is `path`): the shallowest
    /// folder at most `maxDepth` levels below `base` that the index knows as
    /// a meeting folder (also after it was deleted), else one that is a
    /// session folder on disk.
    private func sessionFolder(containing path: String, below base: String, maxDepth: Int, known: Set<String>?) -> String? {
        var candidates: [String] = []
        var current = base
        for part in LibraryPath.components(of: path, below: base).prefix(maxDepth) {
            current = (current as NSString).appendingPathComponent(part)
            candidates.append(current)
        }
        guard !candidates.isEmpty else { return nil }
        let known = known ?? Self.meetingFolders(itemsByID)
        if let hit = candidates.first(where: known.contains) { return hit }
        return candidates.first { MeetingSessionScanner.isSessionFolder(URL(fileURLWithPath: $0, isDirectory: true)) }
    }

    func libraryRootMissing() async -> Bool {
        buildIfNeeded()
        return rootMissing
    }

    /// Called when Roger becomes active: a root that appeared (a drive was
    /// connected) or went away is noticed without a file system event.
    func recheckRoot() async {
        guard isBuilt else { return }
        if Self.isFolder(root) == rootMissing { rebuild() }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Watching

    /// Stops following file system changes. The items stay.
    func stopWatching() {
        watchingStopped = true
        tearDownWatcher()
    }

    private func tearDownWatcher() {
        watcher?.stop()
        watcher = nil
        eventSink?.finish()
        eventSink = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func restartWatcherIfNeeded() {
        guard !watchingStopped else { return }
        let paths = watchedPaths()
        if let watcher, watcher.paths == paths { return }
        tearDownWatcher()
        // Nothing to watch: a missing root and no other folders.
        guard !paths.isEmpty else { return }
        let (events, sink) = AsyncStream.makeStream(of: [String]?.self)
        let watcher = LibraryFolderWatcher(paths: paths, latency: 0.5) { changed, mustRescan in
            sink.yield(mustRescan ? nil : changed)
        }
        guard watcher.start(sinceEventId: scanEventId) else {
            logger.error("Could not watch the library folders")
            return
        }
        self.watcher = watcher
        eventSink = sink
        eventTask = Task { [weak self] in
            for await batch in events {
                guard let self else { return }
                if let batch {
                    await self.apply(changedPaths: batch)
                } else {
                    await self.rebuild()
                }
            }
        }
    }

    /// The library root when it exists (never a parent: that could be all
    /// of `~/Documents`; a root that appears is found by `recheckRoot`), the
    /// extra folders, the folder of the external list and the folders of
    /// external transcripts. FSEvents watches each recursively, so new
    /// `YYYY/MM` folders are covered.
    func watchedPaths() -> [String] {
        var urls: [URL] = rootMissing ? [] : [scope.layout.root]
        urls += scope.extraFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let list = externalListPath {
            urls.append(LibraryPath.nearestExisting(URL(fileURLWithPath: list).deletingLastPathComponent()))
        }
        urls += externalIDs.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        return Array(Set(urls.map { LibraryPath.canonical($0) })).sorted()
    }

    // MARK: - Scanning

    private func buildIfNeeded() {
        if !isBuilt { rebuild() }
    }

    private func reload(_ unit: LibraryScanUnit) {
        switch unit {
        case .file(let path, let kind):
            itemsByID[path] = nil
            if FileManager.default.fileExists(atPath: path),
               let item = LibraryItemReader.item(markdownAt: URL(fileURLWithPath: path), fallbackKind: kind) {
                itemsByID[item.id] = item
            }
        case .session(let path):
            removeAll { $0.kind == .meeting && $0.folderURL.path == path }
            if let item = LibraryItemReader.meetingItem(sessionFolder: URL(fileURLWithPath: path, isDirectory: true)) {
                itemsByID[item.id] = item
            }
        case .tree(let path, let kind):
            removeAll { LibraryPath.isPath($0.url.path, inside: path) || LibraryPath.isPath($0.folderURL.path, inside: path) }
            insert(LibraryScanner.scanTree(path, kind: kind))
        case .extraFolder:
            // Rare (the extra folder itself appeared, went or was renamed).
            // A full read keeps the scanner's rule for a file found twice.
            itemsByID = scanAll()
        case .externalList:
            itemsByID = scanAll()
            // A new external transcript may live in a folder nobody watches yet.
            if watchesFileSystem { restartWatcherIfNeeded() }
        case .everything:
            itemsByID = scanAll()
        }
    }

    private func removeAll(where shouldRemove: (LibraryItem) -> Bool) {
        itemsByID = itemsByID.filter { !shouldRemove($0.value) }
    }

    private func insert(_ items: [LibraryItem]) {
        for item in items { itemsByID[item.id] = item }
    }

    /// The scanner's order and rule: Logs, Transcripts, Meetings, extra
    /// folders, external list; a file found twice keeps its first item.
    /// `externalIDs` holds only the files first found through the list: a
    /// file found twice keeps the kind of its first find after a later edit.
    private func scanAll() -> [String: LibraryItem] {
        var items = LibraryScanner.scanAll(scope: scope, externalFiles: [])
        var seen = Set(items.map(\.id))
        let external = LibraryScanner.scanExternal(externalFiles()).filter { seen.insert($0.id).inserted }
        externalIDs = Set(external.map(\.id))
        items += external
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
