import Foundation
import Testing
@testable import Roger

struct MeetingExtraFilesTests {
    private func touch(_ folder: URL, _ names: [String]) throws {
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
    }

    @Test func classifiesNames() {
        #expect(MeetingExtraFiles.classify("mic.leftover.m4a")?.kind == .micLeftover)
        #expect(MeetingExtraFiles.classify("mic.leftover.m4a")?.number == 0)
        #expect(MeetingExtraFiles.classify("mic.leftover 2.m4a")?.number == 2)
        #expect(MeetingExtraFiles.classify("system.leftover.m4a")?.kind == .systemLeftover)
        #expect(MeetingExtraFiles.classify("mic.previous 1.m4a")?.kind == .micPrevious)
        #expect(MeetingExtraFiles.classify("system.previous.m4a")?.kind == .systemPrevious)
        #expect(MeetingExtraFiles.classify("transcript.previous 1.md")?.kind == .transcriptPrevious)
        #expect(MeetingExtraFiles.classify("2026-10-13 09-05-00.previous.md")?.kind == .segmentPrevious)
        for name in ["mic.m4a", "system.m4a", "transcript.md", "mic-001.caf", "notes.txt",
                     "mic.leftover x.m4a", "speaker.leftover.m4a", ".previous.md", "markers.json"] {
            #expect(MeetingExtraFiles.classify(name) == nil, "\(name)")
        }
    }

    @Test func findsAndOrdersExtraFiles() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, [
            "transcript.md", "mic.m4a", "system.m4a",
            "2026-10-13 09-05-00.previous.md", "transcript.previous.md",
            "system.previous.m4a", "mic.leftover 1.m4a", "mic.leftover.m4a",
        ])
        #expect(MeetingExtraFiles.find(in: folder).map(\.url.lastPathComponent) == [
            "mic.leftover.m4a", "mic.leftover 1.m4a", "system.previous.m4a",
            "transcript.previous.md", "2026-10-13 09-05-00.previous.md",
        ])
    }

    @Test func audioSourcesGetNumberedIDs() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, ["mic.leftover 1.m4a", "mic.leftover.m4a", "system.previous.m4a", "transcript.previous.md"])
        #expect(MeetingExtraFiles.audioSources(in: folder).map { "\($0.id)=\($0.resource)" } == [
            "mic-leftover=mic.leftover.m4a",
            "mic-leftover-2=mic.leftover 1.m4a",
            "system-previous=system.previous.m4a",
        ])
    }

    @Test func transcriptListsExtraAudioInSources() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, ["mic.m4a", "mic.leftover.m4a"])
        let url = try MeetingTranscriptWriter.write(
            paragraphs: [],
            metadata: .init(
                session: MeetingSession(id: UUID(), folder: folder, startedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                durationSeconds: 60, speakerCount: 1, language: nil, micPresent: true, systemPresent: false,
                audioKept: true, diarized: false, diarizationFailed: false, micAudioFailed: true
            )
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("  - { id: mic, resource: \"mic.m4a\" }\n  - { id: mic-leftover, resource: \"mic.leftover.m4a\" }\n"))
    }
}
