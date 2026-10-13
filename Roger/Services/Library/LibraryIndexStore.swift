import Foundation

/// Keeps one live library index for the current library folder and extra
/// folders, so it stays in memory while Roger runs, also after the window
/// closes. A changed scope (new root or extra folders in Settings) gets a
/// fresh index; the old one stops watching.
@MainActor
final class LibraryIndexStore {
    private let externalFiles: @Sendable () -> [URL]
    private let externalListURL: URL?
    private let watchesFileSystem: Bool
    private(set) var current: InMemoryLibraryIndex?

    init(externalFiles: @escaping @Sendable () -> [URL], externalListURL: URL?, watchesFileSystem: Bool) {
        self.externalFiles = externalFiles
        self.externalListURL = externalListURL
        self.watchesFileSystem = watchesFileSystem
    }

    /// The app's store: the real external-transcripts list, with FSEvents.
    static func standard() -> LibraryIndexStore {
        let registry = ExternalTranscriptRegistry.standard
        return LibraryIndexStore(
            externalFiles: { registry.existingFiles() },
            externalListURL: registry.fileURL,
            watchesFileSystem: true
        )
    }

    func index(for scope: LibraryScanScope) -> InMemoryLibraryIndex {
        if let current, current.scope == scope { return current }
        if let old = current {
            Task { await old.stopWatching() }
        }
        let index = InMemoryLibraryIndex(
            scope: scope,
            externalFiles: externalFiles,
            externalListURL: externalListURL,
            watchesFileSystem: watchesFileSystem
        )
        current = index
        return index
    }
}
