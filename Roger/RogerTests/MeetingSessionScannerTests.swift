import Foundation
import Testing
@testable import Roger

struct MeetingSessionScannerTests {
    private func makeSession(_ folder: URL, files: [String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: folder.appendingPathComponent(name))
        }
    }

    @Test func recognisesSessionFolders() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        try makeSession(root.appendingPathComponent("a"), files: ["mic-001.caf"])
        try makeSession(root.appendingPathComponent("b"), files: ["transcript.md"])
        try makeSession(root.appendingPathComponent("c"), files: ["notes.txt"])
        #expect(MeetingSessionScanner.isSessionFolder(root.appendingPathComponent("a")))
        #expect(MeetingSessionScanner.isSessionFolder(root.appendingPathComponent("b")))
        #expect(!MeetingSessionScanner.isSessionFolder(root.appendingPathComponent("c")))
    }

    @Test func findsNestedSessionsInLibrary() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let layout = LibraryLayout(root: root)
        let meetings = layout.kindFolder(.meetings)
        try makeSession(meetings.appendingPathComponent("2026/10/2026-10-13 09-00"), files: ["mic-001.caf"])
        try makeSession(meetings.appendingPathComponent("2026/09/2026-09-01 10-00"), files: ["transcript.md", "mic.m4a"])
        let found = MeetingSessionScanner.sessionFolders(in: meetings, maxDepth: 3).map(\.lastPathComponent).sorted()
        #expect(found == ["2026-09-01 10-00", "2026-10-13 09-00"])
    }

    @Test func doesNotDescendIntoSessions() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("2026-10-13 09-00")
        try makeSession(session, files: ["transcript.md"])
        try makeSession(session.appendingPathComponent("nested"), files: ["mic-001.caf"])
        #expect(MeetingSessionScanner.sessionFolders(in: root, maxDepth: 3) .map(\.lastPathComponent) == ["2026-10-13 09-00"])
    }

    @Test func respectsMaxDepth() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        try makeSession(root.appendingPathComponent("x/y/z/s"), files: ["mic-001.caf"])
        #expect(MeetingSessionScanner.sessionFolders(in: root, maxDepth: 3).isEmpty)
        #expect(MeetingSessionScanner.sessionFolders(in: root, maxDepth: 4).count == 1)
    }

    @Test func combinesLibraryAndLegacyFolders() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        try makeSession(layout.kindFolder(.meetings).appendingPathComponent("2026/10/new"), files: ["mic-001.caf"])
        let legacy = root.appendingPathComponent("Roger Recordings")
        try makeSession(legacy.appendingPathComponent("old"), files: ["system-001.caf"])
        let names = MeetingSessionScanner.allSessionFolders(layout: layout, extraFolders: [legacy, root.appendingPathComponent("missing")])
            .map(\.lastPathComponent).sorted()
        #expect(names == ["new", "old"])
    }

    @Test func overlappingExtraFolderDoesNotListSessionsTwice() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let month = layout.kindFolder(.meetings).appendingPathComponent("2026/10")
        try makeSession(month.appendingPathComponent("s"), files: ["mic-001.caf"])
        // Same month folder twice, once spelled with "..".
        let spelledOtherwise = layout.kindFolder(.meetings).appendingPathComponent("2026/../2026/10")
        let found = MeetingSessionScanner.allSessionFolders(layout: layout, extraFolders: [month, spelledOtherwise])
        #expect(found.map(\.standardizedFileURL.path) == [month.appendingPathComponent("s").standardizedFileURL.path])
    }

    @Test func unfinishedMeansAudioWithoutTranscript() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let cases: [([String], Bool)] = [
            (["mic-001.caf"], true),
            (["mic.m4a"], true),
            (["system.m4a"], true),
            (["mic.m4a", "system.m4a", "markers.json"], true),
            (["transcript.md", "mic-001.caf"], false),
            (["transcript.md", "mic.m4a"], false),
            (["markers.json"], false),
            ([], false),
        ]
        for (index, (files, expected)) in cases.enumerated() {
            let folder = root.appendingPathComponent("s\(index)")
            try makeSession(folder, files: files)
            #expect(MeetingSessionScanner.isUnfinished(folder) == expected, "\(files)")
        }
    }

    @Test func trackSourcePrefersChunksThenExistingArchive() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let archive = root.appendingPathComponent("mic.m4a")
        let chunk = root.appendingPathComponent("mic-001.caf")
        #expect(MeetingTrackSource.resolve(chunks: [], archive: archive) == .absent)
        try Data("audio".utf8).write(to: archive)
        #expect(MeetingTrackSource.resolve(chunks: [], archive: archive) == .existingArchive)
        #expect(MeetingTrackSource.resolve(chunks: [chunk], archive: archive) == .chunks([chunk]))
        // Resolving never touches the archive.
        #expect(try Data(contentsOf: archive) == Data("audio".utf8))
    }

    @Test func chunksAreKeptWhenTheEncodeFails() {
        #expect(MeetingTrackEncodeOutcome.wrote.allowsDeletingChunks(archiveExists: true))
        #expect(!MeetingTrackEncodeOutcome.wrote.allowsDeletingChunks(archiveExists: false))
        #expect(MeetingTrackEncodeOutcome.empty.allowsDeletingChunks(archiveExists: false))
        // A failed encode keeps the chunks, even when an older archive exists.
        #expect(!MeetingTrackEncodeOutcome.failed.allowsDeletingChunks(archiveExists: false))
        #expect(!MeetingTrackEncodeOutcome.failed.allowsDeletingChunks(archiveExists: true))
    }
}
