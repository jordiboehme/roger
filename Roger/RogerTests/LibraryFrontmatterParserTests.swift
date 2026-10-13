import Foundation
import Testing
@testable import Roger

struct LibraryFrontmatterParserTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func splitIsByteExact() {
        let text = "---\ntype: source\n---\n\n# H\n\nBody\n"
        let parts = LibraryFrontmatterParser.split(text)
        #expect(parts.frontmatter == "---\ntype: source\n---\n")
        #expect(parts.body == "\n# H\n\nBody\n")
        #expect(String(parts.frontmatter ?? "") + String(parts.body) == text)
    }

    @Test func textWithoutFrontmatterIsAllBody() {
        let parts = LibraryFrontmatterParser.split("# Just a heading\n")
        #expect(parts.frontmatter == nil)
        #expect(parts.body == "# Just a heading\n")
        #expect(LibraryFrontmatterParser.parse("# Just a heading\n") == nil)
    }

    @Test func unclosedFrontmatterIsAllBody() {
        let text = "---\ntitle: x\nno end here\n"
        #expect(LibraryFrontmatterParser.split(text).frontmatter == nil)
        #expect(LibraryFrontmatterParser.parse(text) == nil)
    }

    @Test func emptyFrontmatterParses() {
        #expect(LibraryFrontmatterParser.parse("---\n---\nBody") == LibraryFrontmatter())
    }

    @Test func readsLogEntry() throws {
        let entry = LogEntry(
            text: "Called the supplier about the delayed shipment",
            startedAt: date,
            endedAt: date.addingTimeInterval(33),
            presetName: "Log",
            language: "de"
        )
        let text = LogEntryWriter.content(for: entry, audioFileName: "2026-10-13 14-32-05.m4a", generatedAt: date)
        let fm = try #require(LibraryFrontmatterParser.parse(text))
        #expect(fm.tags == ["log"])
        #expect(fm.scalars["title"] == LogEntryWriter.title(for: entry))
        #expect(fm.scalars["duration_seconds"] == "33")
        #expect(fm.scalars["preset"] == "Log")
        #expect(fm.scalars["language"] == "de")
        #expect(fm.scalars["status"] == "stable")
        #expect(fm.scalars["started_at"] == TranscriptFrontmatter.timestamp(date))
        #expect(fm.scalars["generated"]?.hasPrefix("{ by: roger/") == true)
        #expect(fm.sources == [.init(id: "audio", resource: "2026-10-13 14-32-05.m4a")])
    }

    @Test func quotedValuesRoundTrip() throws {
        let title = "A \"b\": c\nd\t#e \\ f\u{2028}g"
        let text = TranscriptFrontmatter(
            title: title,
            description: "x",
            tags: ["transcript"],
            sourceDate: date,
            temporalConfidence: .explicit,
            status: "stable"
        ).render()
        let fm = try #require(LibraryFrontmatterParser.parse(text))
        #expect(fm.scalars["title"] == title)
    }

    @Test func readsMediaSource() throws {
        let source = URL(fileURLWithPath: "/tmp/RogerLib/talk.mp4")
        let text = MediaTranscriptFormatter.content(
            source: source,
            destination: URL(fileURLWithPath: "/tmp/RogerLib/talk.mp4.md"),
            recording: .init(startedAt: date, confidence: .explicit, durationSeconds: 90, fileModifiedAt: date),
            paragraphs: [],
            plainText: "Hello",
            language: nil,
            diarized: false,
            diarizationFailed: false
        )
        let fm = try #require(LibraryFrontmatterParser.parse(text))
        #expect(fm.tags == ["transcript"])
        #expect(fm.sources == [.init(id: "media", resource: "talk.mp4")])
        #expect(fm.scalars["resource"] == "talk.mp4")
    }

    @Test func readsBlockListTags() {
        let fm = LibraryFrontmatterParser.parse("---\ntags:\n- meeting\n- transcript\n---\n")
        #expect(fm?.tags == ["meeting", "transcript"])
    }

    @Test func inlineMapKeepsCommasAndColonsInsideQuotes() {
        let map = LibraryFrontmatterParser.inlineMap("{ id: audio, resource: \"a, b: c.m4a\", last_modified: 2026-10-13T14:32:41+02:00 }")
        #expect(map == ["id": "audio", "resource": "a, b: c.m4a", "last_modified": "2026-10-13T14:32:41+02:00"])
    }
}
