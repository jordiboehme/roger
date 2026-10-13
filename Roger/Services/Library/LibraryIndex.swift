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
    var changes: AsyncStream<Void> { get }
}

/// The folders an index covers: the library root and the extra scan folders.
struct LibraryScanScope: Equatable, Sendable {
    let layout: LibraryLayout
    let extraFolders: [URL]
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

    /// `externalFiles` lists transcripts written next to their source
    /// (`ExternalTranscriptRegistry.existingFiles`). `externalListURL` is the
    /// file that list is stored in; a change to it re-reads the list.
    init(
        scope: LibraryScanScope,
        externalFiles: @escaping @Sendable () -> [URL],
        externalListURL: URL? = nil
    ) {
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
        itemsByID = scanAll()
        isBuilt = true
        // Plain locals: Logger interpolation must not touch actor state.
        let count = itemsByID.count
        let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("Library index built: \(count) items in \(milliseconds) ms")
        continuation.yield()
    }

    /// Reads again what `paths` touched. Paths may be spelled as FSEvents
    /// reports them or not. Does nothing before the first build.
    func apply(changedPaths paths: [String]) {
        guard isBuilt else { return }
        let units = Set(paths.compactMap { unit(forChangedPath: $0) })
        guard !units.isEmpty else { return }
        if units.contains(.everything) {
            rebuild()
            return
        }
        let before = itemsByID
        for unit in units { reload(unit) }
        if itemsByID != before { continuation.yield() }
    }

    /// Maps one changed path to what must be read again. Nil for paths
    /// outside the library.
    func unit(forChangedPath raw: String) -> LibraryScanUnit? {
        let path = LibraryPath.canonical(URL(fileURLWithPath: raw))
        if let list = externalListPath, path == list { return .externalList }
        if externalIDs.contains(path) { return .file(path, .transcript) }
        if LibraryPath.isPath(root, inside: path) { return .everything }
        for (folder, kind) in [(logs, LibraryItemKind.log), (transcripts, .transcript)]
        where LibraryPath.isPath(path, inside: folder) {
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "md" { return .file(path, kind) }
            // Audio next to a log entry: its .md says whether it has audio.
            if ext == "m4a" { return .file((path as NSString).deletingPathExtension + ".md", kind) }
            return ext.isEmpty ? .tree(path, kind) : nil
        }
        if LibraryPath.isPath(path, inside: meetings) {
            let parts = LibraryPath.components(of: path, below: meetings)
            // Meetings/YYYY/MM/<session>/...
            if parts.count >= 3 { return .session(([meetings] + parts.prefix(3)).joined(separator: "/")) }
            return .tree(path, .meeting)
        }
        for extra in extras where LibraryPath.isPath(path, inside: extra) {
            let parts = LibraryPath.components(of: path, below: extra)
            guard let first = parts.first else { return .extraFolder(extra) }
            if parts.count == 1 {
                let ext = (first as NSString).pathExtension.lowercased()
                if ext == "md" { return .file(path, .transcript) }
                if !ext.isEmpty { return nil }
            }
            return .session(extra + "/" + first)
        }
        return nil
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
            insert(scanTree(path, kind: kind))
        case .extraFolder(let path):
            removeAll { LibraryPath.isPath($0.url.path, inside: path) }
            insert(scanExtraFolder(path))
        case .externalList:
            let previous = externalIDs
            removeAll { previous.contains($0.id) }
            insert(scanExternal())
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

    private func scanAll() -> [String: LibraryItem] {
        var found = scanTree(logs, kind: .log)
        found += scanTree(transcripts, kind: .transcript)
        found += scanTree(meetings, kind: .meeting)
        for extra in extras { found += scanExtraFolder(extra) }
        found += scanExternal()
        var result: [String: LibraryItem] = [:]
        for item in found { result[item.id] = item }
        return result
    }

    /// Every item at or below `path`. Meetings: session folders up to three
    /// levels down (`YYYY/MM/<session>`). Logs and transcripts: every `.md`
    /// file. Synchronous on purpose: iterating a `DirectoryEnumerator` is
    /// not allowed in async functions under Swift 6.
    private func scanTree(_ path: String, kind: LibraryItemKind) -> [LibraryItem] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if kind == .meeting {
            let sessions = MeetingSessionScanner.isSessionFolder(url)
                ? [url]
                : MeetingSessionScanner.sessionFolders(in: url, maxDepth: 3)
            return sessions.compactMap { LibraryItemReader.meetingItem(sessionFolder: $0) }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var items: [LibraryItem] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "md" {
            if let item = LibraryItemReader.item(markdownAt: file, fallbackKind: kind) { items.append(item) }
        }
        return items
    }

    /// Sessions stored directly in an extra folder (the pre-library meetings
    /// folder) and `.md` files directly inside it (the pre-library custom
    /// transcripts folder).
    private func scanExtraFolder(_ path: String) -> [LibraryItem] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var items = MeetingSessionScanner.sessionFolders(in: url, maxDepth: 1)
            .compactMap { LibraryItemReader.meetingItem(sessionFolder: $0) }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for file in children where file.pathExtension.lowercased() == "md" {
            if let item = LibraryItemReader.item(markdownAt: file, fallbackKind: .transcript) { items.append(item) }
        }
        return items
    }

    private func scanExternal() -> [LibraryItem] {
        var items: [LibraryItem] = []
        var ids: Set<String> = []
        for file in externalFiles() {
            let url = LibraryPath.canonicalURL(file)
            guard let item = LibraryItemReader.item(markdownAt: url, fallbackKind: .transcript) else { continue }
            items.append(item)
            ids.insert(item.id)
        }
        externalIDs = ids
        return items
    }
}
