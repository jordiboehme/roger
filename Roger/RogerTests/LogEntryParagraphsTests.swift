import Foundation
import Testing
@testable import Roger

struct LogEntryParagraphsTests {
    private let start = Date(timeIntervalSince1970: 1_760_511_600) // fixed instant

    private func entry(paragraphs: [MeetingTranscriptMerger.Paragraph]?) -> LogEntry {
        let text = paragraphs?.map(\.text).joined(separator: "\n\n") ?? "Plain words here"
        return LogEntry(text: text, startedAt: start, endedAt: start.addingTimeInterval(65),
                        presetName: "Log", language: "en", paragraphs: paragraphs)
    }

    @Test func plainLogIsUnchanged() {
        let md = LogEntryWriter.content(for: entry(paragraphs: nil), audioFileName: nil, generatedAt: start)
        #expect(!md.contains("speaker_count"))
        #expect(md.hasSuffix("\n\nPlain words here\n"))
    }

    @Test func paragraphsRenderLikeAMeeting() {
        let paragraphs = [
            MeetingTranscriptMerger.Paragraph(speaker: "Me", startTime: 0, text: "Can you hear me?"),
            MeetingTranscriptMerger.Paragraph(speaker: "Other 1", startTime: 3.5, text: "Yes, loud and clear."),
        ]
        let e = entry(paragraphs: paragraphs)
        let md = LogEntryWriter.content(for: e, audioFileName: nil, generatedAt: start)
        #expect(md.contains("speaker_count: 2"))
        let body = paragraphs.map { MeetingTranscriptWriter.paragraphMarkdown($0, sessionStart: start) }.joined()
        #expect(md.contains(body.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(LogEntryWriter.title(for: e).hasSuffix("- Can you hear me"))
    }

    @Test func onlyMeIsStillAValidEntry() {
        let e = entry(paragraphs: [MeetingTranscriptMerger.Paragraph(speaker: "Me", startTime: 0, text: "Just me.")])
        let md = LogEntryWriter.content(for: e, audioFileName: nil, generatedAt: start)
        #expect(md.contains("speaker_count: 1"))
        #expect(md.contains("**Me** [00:00:00"))
    }
}
