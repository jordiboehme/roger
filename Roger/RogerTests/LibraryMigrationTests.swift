import Foundation
import Testing
@testable import Roger

struct LibraryMigrationTests {
    private func makeSession(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: folder.appendingPathComponent("transcript.md"))
    }

    @Test func monthComesFromFolderName() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let old = root.appendingPathComponent("Roger Recordings/2026-03-05 09-30")
        try makeSession(old)
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let moves = LibraryMigration.plan(sessionFolders: [old], layout: layout)
        #expect(moves == [.init(source: old, destinationFolder: layout.kindFolder(.meetings).appendingPathComponent("2026/03", isDirectory: true))])
    }

    @Test func suffixedFolderNameStillParses() {
        let url = URL(fileURLWithPath: "/x/2026-10-13 09-00 1")
        let date = LibraryMigration.sessionDate(for: url)
        #expect(date.map { Calendar.current.component(.month, from: $0) } == 10)
    }

    @Test func detectsFoldersInsideTheLibrary() {
        let layout = LibraryLayout(root: URL(fileURLWithPath: "/tmp/lib/Roger"))
        #expect(LibraryMigration.isInsideLibrary(layout.kindFolder(.meetings), layout: layout))
        #expect(LibraryMigration.isInsideLibrary(URL(fileURLWithPath: "/tmp/lib/Roger/Old/"), layout: layout))
        #expect(LibraryMigration.isInsideLibrary(layout.root, layout: layout))
        #expect(!LibraryMigration.isInsideLibrary(URL(fileURLWithPath: "/tmp/lib/Roger Recordings"), layout: layout))
        #expect(!LibraryMigration.isInsideLibrary(URL(fileURLWithPath: "/tmp/lib"), layout: layout))
    }

    @Test func unparsableNameFallsBackToCreationDate() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let old = root.appendingPathComponent("Weekly sync")
        try makeSession(old)
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let moves = LibraryMigration.plan(sessionFolders: [old], layout: layout)
        let now = Date()
        #expect(moves.first?.destinationFolder == layout.monthFolder(.meetings, for: now))
    }

    @Test func executeMovesAndAvoidsCollisions() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let old = root.appendingPathComponent("Roger Recordings/2026-10-13 09-00")
        try makeSession(old)
        let existing = layout.kindFolder(.meetings).appendingPathComponent("2026/10/2026-10-13 09-00")
        try makeSession(existing)

        let result = LibraryMigration.execute(LibraryMigration.plan(sessionFolders: [old], layout: layout))
        #expect(result.failed.isEmpty)
        #expect(result.moved.map(\.lastPathComponent) == ["2026-10-13 09-00 1"])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("transcript.md").path))
    }

    @Test func executeReportsFailures() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let missing = root.appendingPathComponent("gone")
        let move = LibraryMigration.Move(source: missing, destinationFolder: root.appendingPathComponent("dest"))
        let result = LibraryMigration.execute([move])
        #expect(result.failed == [move])
        #expect(result.moved.isEmpty)
    }
}
