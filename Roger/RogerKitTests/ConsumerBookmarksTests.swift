import Foundation
import Testing
@testable import RogerKit

struct ConsumerBookmarksTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: ["crystalline", "a", "0", "notes-bot-2", String(repeating: "a", count: 64)])
    func validNames(name: String) {
        #expect(ConsumerBookmarks.isValidName(name))
    }

    @Test(arguments: ["", "-a", "A", "a_b", "a.b", "../x", "a/b", "abc\n", "ä", String(repeating: "a", count: 65)])
    func invalidNames(name: String) {
        #expect(!ConsumerBookmarks.isValidName(name))
    }

    @Test func unknownConsumerHasNoBookmark() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        #expect(try ConsumerBookmarks(root: root).bookmark("crystalline") == nil)
    }

    @Test func invalidNameThrows() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        #expect(throws: ConsumerBookmarkError.invalidName("../x")) {
            try ConsumerBookmarks(root: root).ack("../x", upTo: 1, now: now)
        }
    }

    @Test func ackNeverMovesBackwards() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let bookmarks = ConsumerBookmarks(root: root)
        #expect(try bookmarks.ack("crystalline", upTo: 10, now: now) == AckResult(previous: 0, current: 10))
        #expect(try bookmarks.ack("crystalline", upTo: 4, now: now) == AckResult(previous: 10, current: 10))
        #expect(try bookmarks.ack("crystalline", upTo: 12, now: now) == AckResult(previous: 10, current: 12))
        #expect(try bookmarks.bookmark("crystalline")?.seq == 12)
    }

    @Test func fileHasTheSpecShapeAndNoTempFilesRemain() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let bookmarks = ConsumerBookmarks(root: root)
        try bookmarks.ack("crystalline", upTo: 42, now: now)
        let text = try String(contentsOf: bookmarks.folder.appendingPathComponent("crystalline.json"), encoding: .utf8)
        #expect(text == "{\"seq\":42,\"updatedAt\":\"\(RFC3339.string(now))\"}\n")
        let names = try FileManager.default.contentsOfDirectory(atPath: bookmarks.folder.path)
        #expect(names.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func concurrentAcksEndAtTheHighest() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let now = self.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for upTo in (1...200).shuffled() {
                group.addTask {
                    // A fresh value per task: separate lock file handles, like two processes.
                    _ = try ConsumerBookmarks(root: root).ack("crystalline", upTo: upTo, now: now)
                }
            }
            try await group.waitForAll()
        }
        #expect(try ConsumerBookmarks(root: root).bookmark("crystalline")?.seq == 200)
    }

    @Test func listsValidBookmarksOnly() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let bookmarks = ConsumerBookmarks(root: root)
        try bookmarks.ack("zeta", upTo: 3, now: now)
        try bookmarks.ack("alpha", upTo: 5, now: now)
        try Data("{".utf8).write(to: bookmarks.folder.appendingPathComponent("broken.json"))
        try Data("{\"seq\":1,\"updatedAt\":\"2026-10-13T18:02:11+02:00\"}".utf8).write(to: bookmarks.folder.appendingPathComponent("Bad_Name.json"))
        #expect(bookmarks.all().map(\.name) == ["alpha", "zeta"])
    }

    @Test func resetAndForget() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let bookmarks = ConsumerBookmarks(root: root)
        try bookmarks.ack("crystalline", upTo: 9, now: now)
        try bookmarks.reset("crystalline", now: now)
        #expect(try bookmarks.bookmark("crystalline")?.seq == 0)
        try bookmarks.forget("crystalline")
        #expect(try bookmarks.bookmark("crystalline") == nil)
        try bookmarks.forget("crystalline")
    }

    /// The temp file cannot be written: the old bookmark stays, no temp file is left.
    /// The library may be on a drive that is not connected: the bookmarks
    /// never create its root.
    @Test func aMissingRootIsNotCreated() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let root = base.appendingPathComponent("Gone", isDirectory: true)
        let bookmarks = ConsumerBookmarks(root: root)
        #expect(throws: (any Error).self) { try bookmarks.reset("crystalline", now: now) }
        #expect(throws: (any Error).self) { try bookmarks.forget("crystalline") }
        #expect(throws: (any Error).self) { try bookmarks.ack("crystalline", upTo: 1, now: now) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aFailedWriteKeepsTheOldBookmark() throws {
        let root = try TempDir.make()
        let bookmarks = ConsumerBookmarks(root: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bookmarks.folder.path)
            TempDir.remove(root)
        }
        try bookmarks.ack("crystalline", upTo: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bookmarks.folder.path)
        #expect(throws: (any Error).self) { try bookmarks.ack("crystalline", upTo: 5) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bookmarks.folder.path)
        #expect(try bookmarks.bookmark("crystalline")?.seq == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bookmarks.folder.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}
