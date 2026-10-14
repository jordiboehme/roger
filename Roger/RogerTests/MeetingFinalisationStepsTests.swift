import Foundation
import Testing
@testable import Roger

@MainActor
struct MeetingFinalisationStepsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ base: URL) throws -> MeetingSession {
        let folder = base.appendingPathComponent("2026-09-21 16-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MeetingSession(id: UUID(), folder: folder, startedAt: start)
    }

    private func input(
        _ session: MeetingSession,
        paragraphs: [MeetingTranscriptMerger.Paragraph] = [.init(speaker: "Me", startTime: 5, text: "Hello"), .init(speaker: "Other 1", startTime: 40, text: "Hi")],
        audioKept: Bool = true,
        markers: [MeetingCheckpointMarker] = [],
        mic: MeetingFinalisationSteps.Track = .init(),
        system: MeetingFinalisationSteps.Track = .init(),
        sleepInterrupted: Bool = false
    ) -> MeetingFinalisationSteps.Input {
        MeetingFinalisationSteps.Input(
            session: session,
            paragraphs: paragraphs,
            metadata: MeetingTranscriptWriter.Metadata(
                session: session, durationSeconds: 60, speakerCount: 2, language: "en",
                micPresent: true, systemPresent: true, audioKept: audioKept,
                diarized: false, diarizationFailed: false,
                micAudioFailed: mic.audioFailed, systemAudioFailed: system.audioFailed
            ),
            markers: markers,
            segmentStart: start,
            durationSeconds: 60,
            mic: mic,
            system: system,
            sleepInterrupted: sleepInterrupted
        )
    }

    @Test func theTranscriptIsWrittenAndRecordedOnce() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        var recorded: [URL] = []
        guard case .finished(let url, let error) = MeetingFinalisationSteps.run(input(session), recordWritten: { recorded.append($0) }) else {
            Issue.record("expected finished")
            return
        }
        #expect(error == nil)
        #expect(url == session.transcriptURL)
        #expect(recorded == [url])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Hello"))
    }

    @Test func archivesGoOnlyWhenNotKeptAndThereIsText() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        for archive in [session.micArchiveURL, session.systemArchiveURL] { try Data("m4a".utf8).write(to: archive) }
        _ = MeetingFinalisationSteps.run(input(session, paragraphs: [], audioKept: false), recordWritten: { _ in })
        #expect(FileManager.default.fileExists(atPath: session.micArchiveURL.path))
        _ = MeetingFinalisationSteps.run(input(session, audioKept: false), recordWritten: { _ in })
        #expect(!FileManager.default.fileExists(atPath: session.micArchiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: session.systemArchiveURL.path))
    }

    @Test func aFailedTranscriptWriteRecordsAndDeletesNothing() throws {
        let base = try TempFolder.make()
        let session = try session(base)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: session.folder.path)
            TempFolder.remove(base)
        }
        try Data("m4a".utf8).write(to: session.micArchiveURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: session.folder.path)
        var recorded: [URL] = []
        let outcome = MeetingFinalisationSteps.run(input(session, audioKept: false), recordWritten: { recorded.append($0) })
        guard case .failed = outcome else {
            Issue.record("expected failed")
            return
        }
        #expect(recorded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: session.micArchiveURL.path))
    }

    /// The mic needs a retry and the system encode stayed beside its archive:
    /// the error asks for the retry and names the system leftover too.
    @Test func aRetryErrorNamesTheSystemLeftover() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        let leftover = session.folder.appendingPathComponent("system.leftover.m4a")
        let outcome = MeetingFinalisationSteps.run(
            input(session, mic: .init(needsRetry: true), system: .init(leftover: leftover)),
            recordWritten: { _ in }
        )
        guard case .finished(_, let error?) = outcome else {
            Issue.record("expected an error")
            return
        }
        #expect(error.errorDescription?.contains("Try again") == true)
        #expect(error.errorDescription?.contains("system.leftover.m4a") == true)
    }

    @Test func sleepIsReportedWhenNothingElseWentWrong() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        guard case .finished(_, .sleepInterrupted?) = MeetingFinalisationSteps.run(input(session, sleepInterrupted: true), recordWritten: { _ in }) else {
            Issue.record("expected sleepInterrupted")
            return
        }
    }

    @Test func oneSegmentPerMarkerRange() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        let marker = MeetingCheckpointMarker(
            id: UUID(), capturedAt: start.addingTimeInterval(30), offsetSeconds: 30,
            stemDate: start.addingTimeInterval(30), imageFile: "shot.png"
        )
        _ = MeetingFinalisationSteps.run(input(session, markers: [marker]), recordWritten: { _ in })
        let first = session.folder.appendingPathComponent(MeetingSegmentWriter.fileName(chunkStart: start))
        let second = session.folder.appendingPathComponent(MeetingSegmentWriter.fileName(chunkStart: start.addingTimeInterval(31)))
        #expect(try String(contentsOf: first, encoding: .utf8).contains("Hello"))
        #expect(try String(contentsOf: second, encoding: .utf8).contains("Hi"))
    }

    @Test(arguments: [
        (false, MeetingFinalisationSteps.Track(), MeetingFinalisationSteps.Track(), false),
        (true, MeetingFinalisationSteps.Track(), MeetingFinalisationSteps.Track(), true),
        (false, MeetingFinalisationSteps.Track(archiveExisted: true), MeetingFinalisationSteps.Track(), true),
        (false, MeetingFinalisationSteps.Track(), MeetingFinalisationSteps.Track(needsRetry: true), true),
        (false, MeetingFinalisationSteps.Track(leftover: URL(fileURLWithPath: "/x/mic.leftover.m4a")), MeetingFinalisationSteps.Track(), true),
    ])
    func whenAudioIsKept(setting: Bool, mic: MeetingFinalisationSteps.Track, system: MeetingFinalisationSteps.Track, kept: Bool) {
        #expect(MeetingFinalisationSteps.keepsAudio(setting: setting, mic: mic, system: system) == kept)
    }
}
