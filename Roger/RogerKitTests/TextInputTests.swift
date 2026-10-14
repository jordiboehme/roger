import Foundation
import Testing
@testable import RogerKit

/// Files written by other editors: every RogerKit reader sees the same
/// UTF-8 text with LF.
struct TextInputTests {
    @Test(arguments: TextSample.allCases)
    func frontmatterIsFound(_ sample: TextSample) throws {
        let front = try #require(LibraryFrontmatterParser.parse(TextFile.decode(sample.data)))
        #expect(front.scalars["title"] == TextSample.title)
        #expect(front.scalars["started_at"] == "2026-10-13T14:32:05+02:00")
        #expect(front.tags == ["log", "reise"])
    }

    @Test(arguments: TextSample.allCases)
    func readerGivesTheRightItem(_ sample: TextSample) throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("entry.md"))
        let item = try #require(LibraryItemReader.item(markdownAt: url, fallbackKind: .transcript))
        #expect(item.kind == .log)
        #expect(item.title == TextSample.title)
        #expect(item.date == TextSample.startedAt)
        #expect(item.durationSeconds == 33)
        #expect(item.firstLine == TextSample.firstLine)
        #expect(item.searchText.contains("ärger über die lieferung"))
        #expect(!item.searchText.contains("\r"))
    }

    @Test(arguments: TextSample.allCases)
    func markdownForToolsIsUTF8WithLF(_ sample: TextSample) throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("entry.md"))
        let item = try #require(LibraryItemReader.item(markdownAt: url, fallbackKind: .log))
        #expect(ItemResolver.markdown(of: item) == TextSample.text)
        let hit = try #require(ItemSearch.search("lieferung", in: [item], kind: nil, limit: 5).first)
        #expect(hit.snippet.contains("Ärger über die Lieferung"))
    }

    @Test func failedAudioFlagIsFoundInACRLFTranscript() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let transcript = folder.appendingPathComponent("transcript.md")
        try Data("---\r\ntags: [meeting, transcript]\r\nmic_audio_failed: true\r\n---\r\n# Meeting\r\n".utf8).write(to: transcript)
        #expect(MeetingSessionScanner.transcriptReportsFailedAudio(transcript))
    }
}
