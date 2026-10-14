import Foundation

/// The folders a scan covers: the library root and the extra scan folders.
public struct LibraryScanScope: Equatable, Sendable {
    public let layout: LibraryLayout
    public let extraFolders: [URL]

    public init(layout: LibraryLayout, extraFolders: [URL]) {
        self.layout = layout
        self.extraFolders = extraFolders
    }
}

/// Reads every item in a scope from disk. Used by the library index, the
/// change log's catch-up and `roger-mcp`. Paths are canonical. Hidden files
/// and folders (including `<root>/.roger/`) are skipped.
public enum LibraryScanner {
    /// Logs, transcripts and meetings below the root, sessions and `.md`
    /// files directly in each extra folder, and the external transcripts.
    /// One item per canonical path (first found wins).
    public static func scanAll(scope: LibraryScanScope, externalFiles: [URL]) -> [LibraryItem] {
        let layout = scope.layout
        var found = scanTree(LibraryPath.canonical(layout.kindFolder(.logs)), kind: .log)
        found += scanTree(LibraryPath.canonical(layout.kindFolder(.transcripts)), kind: .transcript)
        found += scanTree(LibraryPath.canonical(layout.kindFolder(.meetings)), kind: .meeting)
        for extra in scope.extraFolders {
            found += scanExtraFolder(LibraryPath.canonical(extra))
        }
        found += scanExternal(externalFiles)
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// Every item at or below `path`. Meetings: session folders up to three
    /// levels down (`YYYY/MM/<session>`). Logs and transcripts: every `.md`
    /// file. Synchronous on purpose: iterating a `DirectoryEnumerator` is
    /// not allowed in async functions under Swift 6.
    public static func scanTree(_ path: String, kind: LibraryItemKind) -> [LibraryItem] {
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
    public static func scanExtraFolder(_ path: String) -> [LibraryItem] {
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

    /// Transcripts written next to their source file.
    public static func scanExternal(_ files: [URL]) -> [LibraryItem] {
        files.compactMap { file in
            LibraryItemReader.item(markdownAt: LibraryPath.canonicalURL(file), fallbackKind: .transcript)
        }
    }
}
