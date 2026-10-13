import Foundation
import Testing
@testable import Roger

struct MeetingTranscriptWriterTests {
    private func metadata(_ folder: URL, micFailed: Bool, systemFailed: Bool) -> MeetingTranscriptWriter.Metadata {
        MeetingTranscriptWriter.Metadata(
            session: MeetingSession(id: UUID(), folder: folder, startedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            durationSeconds: 60,
            speakerCount: 1,
            language: nil,
            micPresent: true,
            systemPresent: false,
            audioKept: true,
            diarized: false,
            diarizationFailed: false,
            micAudioFailed: micFailed,
            systemAudioFailed: systemFailed
        )
    }

    @Test func flagsFailedAudioTracks() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let url = try MeetingTranscriptWriter.write(paragraphs: [], metadata: metadata(root, micFailed: false, systemFailed: true))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\nsystem_audio_failed: true\n"))
        #expect(!text.contains("mic_audio_failed"))
    }

    @Test func noFlagsWhenAudioIsFine() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let url = try MeetingTranscriptWriter.write(paragraphs: [], metadata: metadata(root, micFailed: false, systemFailed: false))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("audio_failed"))
    }

    @Test func existingTranscriptIsMovedAsideNotOverwritten() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let transcript = root.appendingPathComponent("transcript.md")
        try Data("edited by hand".utf8).write(to: transcript)
        try Data("older copy".utf8).write(to: root.appendingPathComponent("transcript.previous.md"))
        _ = try MeetingTranscriptWriter.write(paragraphs: [], metadata: metadata(root, micFailed: false, systemFailed: false))
        #expect(try String(contentsOf: root.appendingPathComponent("transcript.previous.md"), encoding: .utf8) == "older copy")
        #expect(try String(contentsOf: root.appendingPathComponent("transcript.previous 1.md"), encoding: .utf8) == "edited by hand")
        #expect(try String(contentsOf: transcript, encoding: .utf8).hasPrefix("---\n"))
    }
}
