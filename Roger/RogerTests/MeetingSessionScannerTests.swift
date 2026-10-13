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
        let a = URL(fileURLWithPath: "/s/mic-001.caf")
        let b = URL(fileURLWithPath: "/s/mic-002.caf")
        let c = URL(fileURLWithPath: "/s/mic-003.caf")
        typealias R = AudioSegmentConcatenator.Result
        // Encode threw: keep everything, even when an older archive exists.
        #expect(MeetingTrackEncodeOutcome.failed.deletableChunks(archiveExists: true).isEmpty)
        #expect(MeetingTrackEncodeOutcome.failed.isFailure)
        // Archive written: delete inserted and empty chunks, keep unreadable ones.
        let partial = MeetingTrackEncodeOutcome.encoded(R(inserted: [a], empty: [b], unreadable: [c]))
        #expect(partial.deletableChunks(archiveExists: true) == [a, b])
        #expect(partial.deletableChunks(archiveExists: false).isEmpty)
        #expect(!partial.isFailure)
        // Nothing written, all empty: no audio to lose.
        let silent = MeetingTrackEncodeOutcome.encoded(R(empty: [a, b]))
        #expect(silent.deletableChunks(archiveExists: false) == [a, b])
        #expect(!silent.isFailure)
        // Nothing written, some unreadable: a failure, keep everything.
        let broken = MeetingTrackEncodeOutcome.encoded(R(empty: [a], unreadable: [b]))
        #expect(broken.deletableChunks(archiveExists: false).isEmpty)
        #expect(broken.isFailure)
    }

    @Test func transcriptWithFailedAudioAndLeftoverChunksIsUnfinished() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        func session(_ name: String, frontmatter: String, files: [String]) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try makeSession(folder, files: files)
            try Data("---\ntype: source\n\(frontmatter)---\n\n# Meeting\n".utf8)
                .write(to: folder.appendingPathComponent("transcript.md"))
            return folder
        }
        let failedWithChunks = try session("a", frontmatter: "system_audio_failed: true\n", files: ["mic.m4a", "system-001.caf"])
        let micFailed = try session("b", frontmatter: "mic_audio_failed: true\n", files: ["mic-001.caf"])
        let failedNoChunks = try session("c", frontmatter: "system_audio_failed: true\n", files: ["mic.m4a"])
        let chunksNoFlag = try session("d", frontmatter: "", files: ["system-001.caf"])
        #expect(MeetingSessionScanner.isUnfinished(failedWithChunks))
        #expect(MeetingSessionScanner.isUnfinished(micFailed))
        #expect(!MeetingSessionScanner.isUnfinished(failedNoChunks))
        #expect(!MeetingSessionScanner.isUnfinished(chunksNoFlag))
    }

    @Test func unreadableChunksMeanTheTrackNeedsARetry() {
        let a = URL(fileURLWithPath: "/s/mic-001.caf")
        let b = URL(fileURLWithPath: "/s/mic-002.caf")
        typealias R = AudioSegmentConcatenator.Result
        #expect(MeetingTrackEncodeOutcome.encoded(R(inserted: [a], unreadable: [b])).needsRetry)
        #expect(MeetingTrackEncodeOutcome.encoded(R(unreadable: [b])).needsRetry)
        #expect(MeetingTrackEncodeOutcome.failed.needsRetry)
        #expect(!MeetingTrackEncodeOutcome.encoded(R(inserted: [a], empty: [b])).needsRetry)
    }

    @Test func dismissedPathsArePrunedWhenTheFolderIsGone() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let kept = root.appendingPathComponent("kept")
        try makeSession(kept, files: ["mic-001.caf"])
        let gone = root.appendingPathComponent("gone").path
        #expect(MeetingSessionScanner.existingFolderPaths([kept.path, gone]) == [kept.path])
    }
}
