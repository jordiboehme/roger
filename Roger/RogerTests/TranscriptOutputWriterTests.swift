import Foundation
import Testing
@testable import Roger

struct TranscriptOutputWriterTests {
    @Test func libraryLocationUsesTranscriptsMonthFolder() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let source = root.appendingPathComponent("talk.mp4")
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 13; c.hour = 12
        let now = Calendar.current.date(from: c)!
        let url = try TranscriptOutputWriter.write(
            source: source, location: .library, layout: LibraryLayout(root: root.appendingPathComponent("Lib")), now: now
        ) { _ in "body" }
        #expect(url.path == root.appendingPathComponent("Lib/Transcripts/2026/10/talk.mp4.md").path)
    }

    @Test func alongsideSourceWritesNextToSource() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let source = root.appendingPathComponent("talk.mp4")
        let url = try TranscriptOutputWriter.write(
            source: source, location: .alongsideSource, layout: LibraryLayout(root: root.appendingPathComponent("Lib"))
        ) { _ in "body" }
        #expect(url.path == root.appendingPathComponent("talk.mp4.md").path)
    }

    @Test func collisionAddsSpaceAndNumberBeforeMd() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let source = root.appendingPathComponent("talk.mp4")
        let layout = LibraryLayout(root: root.appendingPathComponent("Lib"))
        let names = try (0..<3).map { _ in
            try TranscriptOutputWriter.write(source: source, location: .alongsideSource, layout: layout) { _ in "body" }
                .lastPathComponent
        }
        #expect(names == ["talk.mp4.md", "talk.mp4 1.md", "talk.mp4 2.md"])
    }

    @Test func legacyCustomFolderValueFallsBackToLibrary() {
        #expect(FileTranscriptOutputLocation(rawValue: "customFolder") == nil)
        #expect(FileTranscriptOutputLocation.allCases == [.library, .alongsideSource])
    }
}
