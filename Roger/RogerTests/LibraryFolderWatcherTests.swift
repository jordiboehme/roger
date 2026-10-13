import Foundation
import Testing
@testable import Roger

private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ paths: [String]) { lock.withLock { stored += paths } }
    var paths: [String] { lock.withLock { stored } }
}

struct LibraryFolderWatcherTests {
    @Test(.timeLimit(.minutes(1))) func watcherReportsNewFiles() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let collector = PathCollector()
        let watcher = LibraryFolderWatcher(paths: [LibraryPath.canonical(root)], latency: 0.1) { paths, _ in
            collector.add(paths)
        }
        #expect(watcher.start())
        defer { watcher.stop() }
        // FSEvents needs a moment after start before it reports.
        try await Task.sleep(for: .milliseconds(300))
        let file = root.appendingPathComponent("new.md")
        try Data("x".utf8).write(to: file)
        let expected = LibraryPath.canonical(file)
        var seen = false
        for _ in 0..<50 where !seen {
            seen = collector.paths.contains(expected)
            if !seen { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(seen)
    }

    @Test(.timeLimit(.minutes(1))) func watcherKeepsIndexCurrent() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let index = InMemoryLibraryIndex(
            scope: LibraryScanScope(layout: layout, extraFolders: []),
            externalFiles: { [] },
            watchesFileSystem: true
        )
        #expect(await index.items().isEmpty)
        try await Task.sleep(for: .milliseconds(300))

        // A month folder that did not exist when the index was built.
        let folder = layout.monthFolder(.logs, for: Date(timeIntervalSince1970: 1_790_000_000))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fm = TranscriptFrontmatter(
            title: "Live", description: "x", tags: ["log"],
            sourceDate: .now, temporalConfidence: .explicit, status: "stable"
        )
        try (fm.render() + "# Live\n\nWritten while watching\n")
            .write(to: folder.appendingPathComponent("live.md"), atomically: true, encoding: .utf8)

        var titles: [String] = []
        for _ in 0..<50 where titles != ["Live"] {
            titles = await index.items().map(\.title)
            if titles != ["Live"] { try await Task.sleep(for: .milliseconds(100)) }
        }
        await index.stopWatching()
        #expect(titles == ["Live"])
    }
}
