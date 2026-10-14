import Foundation
import Testing
@testable import RogerKit

/// An unfinished meeting that only has its recording chunks (a crash
/// before finalisation) shows its audio and its screenshots.
struct UnfinishedMeetingItemTests {
    private func session(_ base: URL, files: [String]) throws -> URL {
        let folder = base.appendingPathComponent("2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try Data().write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    @Test func chunksCountAsAudio() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["system-001.caf", "mic-002.caf", "mic-001.caf", ".mic-003.caf"])
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.isUnfinished)
        #expect(item.hasAudio)
        #expect(item.audioFiles.map(\.lastPathComponent) == ["mic-001.caf", "mic-002.caf", "system-001.caf"])
    }

    @Test func archivesComeBeforeChunks() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["mic-001.caf", "system.m4a"])
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.audioFiles.map(\.lastPathComponent) == ["system.m4a", "mic-001.caf"])
    }

    @Test func screenshotsAreCountedWithoutMarkers() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["mic-001.caf", "2026-10-13 09-05-00.png", "2026-10-13 09-10-00.PNG", "notes.txt"])
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.screenshotCount == 2)
    }

    @Test func markersWinOverTheFolderCount() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["mic-001.caf", "a.png", "b.png"])
        let json = #"{"markers":[{}],"sessionStartedAt":"2026-10-13T07:00:00Z","version":1}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("markers.json"))
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.screenshotCount == 1)
    }
}
