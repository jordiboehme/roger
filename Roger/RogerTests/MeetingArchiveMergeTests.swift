import Foundation
import Testing
@testable import Roger

struct MeetingArchiveMergeTests {
    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func siblingNamesAreUnique() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let archive = root.appendingPathComponent("mic.m4a")
        #expect(MeetingArchiveMerge.leftoverURL(for: archive).lastPathComponent == "mic.leftover.m4a")
        try write("x", to: root.appendingPathComponent("mic.leftover.m4a"))
        #expect(MeetingArchiveMerge.leftoverURL(for: archive).lastPathComponent == "mic.leftover 1.m4a")
    }

    @Test func keepingTheEncodedFileMovesTheOldArchiveAside() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let archive = root.appendingPathComponent("mic.m4a")
        let encoded = root.appendingPathComponent("mic.leftover.m4a")
        try write("old", to: archive)
        try write("new", to: encoded)
        try MeetingArchiveMerge.settle(archive: archive, encoded: encoded, keepEncoded: true)
        #expect(try read(archive) == "new")
        #expect(try read(root.appendingPathComponent("mic.previous.m4a")) == "old")
        #expect(!FileManager.default.fileExists(atPath: encoded.path))
    }

    @Test func keepingTheOldArchiveLeavesBothFiles() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let archive = root.appendingPathComponent("mic.m4a")
        let encoded = root.appendingPathComponent("mic.leftover.m4a")
        try write("old", to: archive)
        try write("new", to: encoded)
        try MeetingArchiveMerge.settle(archive: archive, encoded: encoded, keepEncoded: false)
        #expect(try read(archive) == "old")
        #expect(try read(encoded) == "new")
    }

    @Test func failedMoveRestoresTheOldArchive() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let archive = root.appendingPathComponent("mic.m4a")
        try write("old", to: archive)
        let missing = root.appendingPathComponent("mic.leftover.m4a")
        #expect(throws: (any Error).self) {
            try MeetingArchiveMerge.settle(archive: archive, encoded: missing, keepEncoded: true)
        }
        #expect(try read(archive) == "old")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mic.previous.m4a").path))
    }

    @Test func moveAsidePicksTheNextFreeName() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = folder.appendingPathComponent("transcript.md")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        #expect(try MeetingArchiveMerge.moveAside(url).lastPathComponent == "transcript.previous.md")
        try "two".write(to: url, atomically: true, encoding: .utf8)
        #expect(try MeetingArchiveMerge.moveAside(url).lastPathComponent == "transcript.previous 1.md")
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.previous.md"), encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
