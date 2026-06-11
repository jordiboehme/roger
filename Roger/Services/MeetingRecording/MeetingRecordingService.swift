import AppKit
import AVFoundation
import FluidAudio
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingRecording")

/// Orchestrates a meeting-recording session: mic + system tap → CAF chunks
/// per track → finalisation pipeline (encode each track to M4A, run Whisper
/// per track, diarize the system track, merge → markdown). All UI-observable
/// state is reachable via `@Observable`.
@MainActor
@Observable
final class MeetingRecordingService {
    enum State: Equatable, Sendable {
        case idle
        case starting
        case recording(startedAt: Date)
        case finalising(progress: Double)
        case error(MeetingRecordingError)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.starting, .starting):
                return true
            case (.recording(let a), .recording(let b)):
                return a == b
            case (.finalising(let a), .finalising(let b)):
                return abs(a - b) < 0.001
            case (.error(let a), .error(let b)):
                return a.localizedDescription == b.localizedDescription
            default:
                return false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var lastSession: MeetingSession?

    private let appState: AppState
    private let transcriptionEngine: TranscriptionEngine
    private let diarization: DiarizationService

    private var session: MeetingSession?
    private var micTap: MicrophoneTap?
    private var systemTap: SystemAudioTap?
    private var micWriter: SegmentedAudioFileWriter?
    private var systemWriter: SegmentedAudioFileWriter?
    private var micConsumerTask: Task<Void, Never>?
    private var systemConsumerTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var stopRequested = false

    init(
        appState: AppState,
        transcriptionEngine: TranscriptionEngine,
        diarization: DiarizationService
    ) {
        self.appState = appState
        self.transcriptionEngine = transcriptionEngine
        self.diarization = diarization
    }

    var isActive: Bool {
        switch state {
        case .idle, .error: return false
        default: return true
        }
    }

    /// Starts a new session: creates the folder, opens both writers, hooks up
    /// taps. Throws if anything trips before audio actually flows; on a thrown
    /// error the partial session folder is removed.
    func start() async throws {
        guard !isActive else {
            throw MeetingRecordingError.alreadyRecording
        }

        state = .starting

        let parent = resolvedRecordingsFolder()
        let session: MeetingSession
        do {
            session = try MeetingSession.create(in: parent)
        } catch {
            state = .error(.audioWriterFailed(error.localizedDescription))
            throw MeetingRecordingError.audioWriterFailed(error.localizedDescription)
        }
        self.session = session

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SystemAudioTap.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        let segmentDuration = TimeInterval(max(60, appState.meetingMaxSegmentMinutes * 60))

        let micWriter = SegmentedAudioFileWriter(
            folder: session.folder,
            baseName: "mic",
            format: format,
            segmentDuration: segmentDuration
        )
        let systemWriter = SegmentedAudioFileWriter(
            folder: session.folder,
            baseName: "system",
            format: format,
            segmentDuration: segmentDuration
        )

        do {
            try micWriter.start()
            try systemWriter.start()
        } catch {
            state = .error(.audioWriterFailed(error.localizedDescription))
            try? FileManager.default.removeItem(at: session.folder)
            throw MeetingRecordingError.audioWriterFailed(error.localizedDescription)
        }

        let micTap = MicrophoneTap()
        micTap.preferredInputUID = appState.selectedInputDeviceUID
        let systemTap = SystemAudioTap()

        let micStream: AsyncStream<SendableAudioBuffer>
        let systemStream: AsyncStream<SendableAudioBuffer>
        do {
            micStream = try micTap.startStreaming()
        } catch let error as MicrophoneTapError where error == .permissionDenied {
            await teardown(session: session, deleteFolder: true)
            state = .error(.microphonePermissionDenied)
            throw MeetingRecordingError.microphonePermissionDenied
        } catch {
            await teardown(session: session, deleteFolder: true)
            state = .error(.tapStartFailed(error.localizedDescription))
            throw MeetingRecordingError.tapStartFailed(error.localizedDescription)
        }
        do {
            systemStream = try systemTap.startStreaming()
        } catch {
            micTap.stop()
            await teardown(session: session, deleteFolder: true)
            state = .error(.tapStartFailed(error.localizedDescription))
            throw MeetingRecordingError.tapStartFailed(error.localizedDescription)
        }

        self.micTap = micTap
        self.systemTap = systemTap
        self.micWriter = micWriter
        self.systemWriter = systemWriter
        self.stopRequested = false

        micConsumerTask = Task.detached { [weak self] in
            await self?.consume(stream: micStream, into: micWriter)
        }
        systemConsumerTask = Task.detached { [weak self] in
            await self?.consume(stream: systemStream, into: systemWriter)
        }

        installSleepObserver()

        state = .recording(startedAt: session.startedAt)
        logger.notice("Meeting recording started in \(session.folder.path, privacy: .public)")
    }

    /// Stops the session and runs the finalisation pipeline. Idempotent.
    func stop() async {
        guard case .recording = state else { return }
        await finalise(reason: .userStopped)
    }

    /// Tears down the session without finalisation. Used when permission
    /// errors occur during start() or when the session must be abandoned.
    func cancel() async {
        guard let session else {
            state = .idle
            return
        }
        await teardown(session: session, deleteFolder: false)
        state = .idle
    }

    /// Recovery scan: finds session folders that contain CAF chunks but no
    /// transcript.md, indicating a prior crash mid-recording. Returns the
    /// list. Caller can prompt the user, then call `finaliseRecovered(_:)`.
    func unfinalisedSessions() -> [MeetingSession] {
        let parent = resolvedRecordingsFolder()
        let fm = FileManager.default
        guard fm.fileExists(atPath: parent.path) else { return [] }
        let contents = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var result: [MeetingSession] = []
        for url in contents where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let cafs = (try? fm.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".caf") }) ?? []
            let transcriptExists = fm.fileExists(atPath: url.appendingPathComponent("transcript.md").path)
            guard !cafs.isEmpty, !transcriptExists else { continue }
            let started = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            result.append(MeetingSession(id: UUID(), folder: url, startedAt: started))
        }
        return result
    }

    /// Re-runs concatenation + transcription against an existing session
    /// folder that already contains CAF chunks.
    func finaliseRecovered(_ session: MeetingSession) async {
        guard !isActive else {
            logger.warning("Recovery requested while a session is active — ignored")
            return
        }
        self.session = session
        await runFinalisationPipeline()
    }

    // MARK: - Internals

    private func resolvedRecordingsFolder() -> URL {
        if let url = appState.meetingRecordingsFolder {
            return url
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Roger Recordings", isDirectory: true)
    }

    private func consume(
        stream: AsyncStream<SendableAudioBuffer>,
        into writer: SegmentedAudioFileWriter
    ) async {
        for await wrapper in stream {
            writer.append(wrapper.buffer)
        }
    }

    private enum FinaliseReason {
        case userStopped
        case sleepInterrupted
        case writerFailed(Error)
    }

    private func finalise(reason: FinaliseReason) async {
        stopRequested = true
        // Stop taps first — this drains writer streams.
        micTap?.stop()
        systemTap?.stop()
        // Wait briefly for writer queues to absorb the last buffers.
        try? await Task.sleep(nanoseconds: 250_000_000)
        micConsumerTask?.cancel()
        systemConsumerTask?.cancel()
        _ = await micConsumerTask?.value
        _ = await systemConsumerTask?.value
        micConsumerTask = nil
        systemConsumerTask = nil
        removeSleepObserver()

        await runFinalisationPipeline(sleepInterrupted: {
            if case .sleepInterrupted = reason { return true }
            return false
        }())
    }

    private func runFinalisationPipeline(sleepInterrupted: Bool = false) async {
        guard let session else {
            state = .idle
            return
        }
        state = .finalising(progress: 0.05)

        // Close writers and collect chunk URLs.
        let micSegments = await micWriter?.close() ?? gatherChunks(in: session.folder, prefix: "mic")
        let systemSegments = await systemWriter?.close() ?? gatherChunks(in: session.folder, prefix: "system")
        micWriter = nil
        systemWriter = nil

        // Encode each track.
        state = .finalising(progress: 0.15)
        let micArchive = session.micArchiveURL
        let systemArchive = session.systemArchiveURL

        var micPresent = !micSegments.isEmpty
        var systemPresent = !systemSegments.isEmpty

        if micPresent {
            do {
                let wrote = try await AudioSegmentConcatenator.concatenate(segments: micSegments, destinationURL: micArchive)
                micPresent = wrote
            } catch {
                logger.error("Mic encode failed: \(error.localizedDescription, privacy: .public)")
                state = .error(.finalisationFailed("Mic encode failed: \(error.localizedDescription)"))
                return
            }
        }
        state = .finalising(progress: 0.30)
        if systemPresent {
            do {
                let wrote = try await AudioSegmentConcatenator.concatenate(segments: systemSegments, destinationURL: systemArchive)
                systemPresent = wrote
            } catch {
                // System-side encode failures should NOT block the rest of
                // the pipeline — the mic transcript is still useful. Log
                // loudly, mark the track absent, and continue.
                logger.error("System encode failed (continuing without system audio): \(error.localizedDescription, privacy: .public)")
                systemPresent = false
            }
        }

        // Delete CAF chunks once their target encode either landed or was
        // confirmed empty. We don't keep dead chunks around — re-running the
        // recovery pipeline against an empty CAF folder produces the same
        // result anyway.
        if FileManager.default.fileExists(atPath: micArchive.path) || !micPresent {
            for url in micSegments { try? FileManager.default.removeItem(at: url) }
        }
        if FileManager.default.fileExists(atPath: systemArchive.path) || !systemPresent {
            for url in systemSegments { try? FileManager.default.removeItem(at: url) }
        }

        guard transcriptionEngine.isReady else {
            // Audio is on disk; transcription can be retried later. Surface
            // an error so the user knows the .md isn't there yet.
            state = .error(.finalisationFailed("Speech model isn't loaded — audio saved, transcript will be empty."))
            lastSession = session
            return
        }

        state = .finalising(progress: 0.45)

        // Resolve the post-processing preset once so both transcription
        // calls and the per-paragraph cleanup share the same language pin.
        // `meetingTranscriptionPreset` is guaranteed to have no AI steps;
        // `resolvedLanguage` enforces the model-vs-preset precedence (the
        // English-only model always wins, matching the existing behaviour
        // in PresetsSettingsView's mismatch warning).
        let postProcessingPreset = appState.meetingTranscriptionPreset
        let languageOverride = appState.resolvedLanguage(for: postProcessingPreset)

        // Mic transcription — and optional diarization when the user has
        // turned on shared-mic detection. Whichever path the result follows,
        // we end up with a `MeetingTranscriptMerger.MicInput`.
        var micInput: MeetingTranscriptMerger.MicInput = .none
        var micLanguage: String?
        var diarizationFailed = false
        if micPresent {
            do {
                let detailed = try await transcriptionEngine.transcribeFileDetailed(
                    url: micArchive,
                    languageOverride: languageOverride
                )
                micLanguage = detailed.result.detectedLanguage

                if appState.meetingDiarizeMic {
                    do {
                        let segments = try await diarization.speakerSegments(
                            samples: detailed.audioSamples,
                            tokens: detailed.tokenTimings
                        )
                        micInput = .diarized(segments)
                    } catch {
                        diarizationFailed = true
                        logger.warning("Mic diarization failed: \(error.localizedDescription, privacy: .public) — falling back to flat Me labels")
                        micInput = .flat(SpeakerAligner.segment(tokens: detailed.tokenTimings))
                    }
                } else {
                    micInput = .flat(SpeakerAligner.segment(tokens: detailed.tokenTimings))
                }
            } catch {
                logger.warning("Mic transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        state = .finalising(progress: 0.65)

        // System transcription + diarization.
        var systemSpeakerSegments: [SpeakerSegment] = []
        var systemLanguage: String?
        if systemPresent {
            do {
                let detailed = try await transcriptionEngine.transcribeFileDetailed(
                    url: systemArchive,
                    languageOverride: languageOverride
                )
                systemLanguage = detailed.result.detectedLanguage
                if appState.meetingDiarizeSystem {
                    do {
                        systemSpeakerSegments = try await diarization.speakerSegments(
                            samples: detailed.audioSamples,
                            tokens: detailed.tokenTimings
                        )
                    } catch {
                        diarizationFailed = true
                        logger.warning("System diarization failed: \(error.localizedDescription, privacy: .public)")
                        systemSpeakerSegments = fallbackOtherSegments(tokens: detailed.tokenTimings)
                    }
                } else {
                    systemSpeakerSegments = fallbackOtherSegments(tokens: detailed.tokenTimings)
                }
            } catch {
                logger.warning("System transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        state = .finalising(progress: 0.85)

        // Merge + post-process + write transcript. Cleanup runs per-paragraph
        // so dedup and filler removal stay scoped to a single speaker. AI
        // steps are off by construction (`meetingTranscriptionPreset` is
        // guaranteed to have `requiresAI == false`), so passing
        // `llmService: nil` is safe and stays fully on-device.
        let mergedParagraphs = MeetingTranscriptMerger.merge(
            mic: micInput,
            systemSpeakerSegments: systemSpeakerSegments
        )

        let resolvedLanguageCode = micLanguage ?? systemLanguage
        let languageHint: String = resolvedLanguageCode.map { WhisperLanguage.displayName(for: $0) }
            ?? appState.transcriptionMode.languageHint
            ?? "the original language"

        let postProcessor = PostProcessor()
        var paragraphs: [MeetingTranscriptMerger.Paragraph] = []
        for paragraph in mergedParagraphs {
            let cleaned: String
            do {
                cleaned = try await postProcessor.process(
                    paragraph.text,
                    preset: postProcessingPreset,
                    language: languageHint,
                    llmService: nil
                )
            } catch {
                logger.warning("Paragraph post-processing failed (\(postProcessingPreset.name, privacy: .public)): \(error.localizedDescription, privacy: .public) — keeping raw text")
                paragraphs.append(paragraph)
                continue
            }
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            paragraphs.append(MeetingTranscriptMerger.Paragraph(
                speaker: paragraph.speaker,
                startTime: paragraph.startTime,
                text: trimmed
            ))
        }

        let durationSeconds = computeDurationSeconds(
            startedAt: session.startedAt,
            micArchive: micPresent ? micArchive : nil,
            systemArchive: systemPresent ? systemArchive : nil
        )

        let speakerCount = countSpeakers(paragraphs: paragraphs)
        let metadata = MeetingTranscriptWriter.Metadata(
            session: session,
            durationSeconds: durationSeconds,
            speakerCount: speakerCount,
            language: micLanguage ?? systemLanguage,
            micPresent: micPresent,
            systemPresent: systemPresent,
            diarizationFailed: diarizationFailed,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            modelDescription: "Parakeet TDT v3"
        )

        do {
            _ = try MeetingTranscriptWriter.write(paragraphs: paragraphs, metadata: metadata)
        } catch {
            state = .error(.finalisationFailed(error.localizedDescription))
            lastSession = session
            return
        }

        if sleepInterrupted {
            state = .error(.sleepInterrupted)
        } else {
            state = .idle
        }
        lastSession = session
        self.session = nil
        logger.notice("Meeting recording finalised at \(session.folder.path, privacy: .public)")
    }

    /// Builds a single-speaker ("S0") segment list from the ASR token timings so
    /// the merger labels the whole system track "Other 1" when diarization is
    /// off or failed.
    private func fallbackOtherSegments(tokens: [TokenTiming]) -> [SpeakerSegment] {
        SpeakerAligner.segment(tokens: tokens).map { seg in
            SpeakerSegment(speakerId: "S0", startTime: seg.startTime, endTime: seg.endTime, text: seg.text)
        }
    }

    private func computeDurationSeconds(startedAt: Date, micArchive: URL?, systemArchive: URL?) -> Int {
        let candidates: [URL] = [micArchive, systemArchive].compactMap { $0 }
        var maxDuration: Double = 0
        for url in candidates {
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(asset.duration)
            if duration.isFinite && duration > maxDuration {
                maxDuration = duration
            }
        }
        if maxDuration > 0 { return Int(maxDuration.rounded()) }
        return Int(Date().timeIntervalSince(startedAt).rounded())
    }

    private func countSpeakers(paragraphs: [MeetingTranscriptMerger.Paragraph]) -> Int {
        var labels = Set<String>()
        for p in paragraphs { labels.insert(p.speaker) }
        return labels.count
    }

    private func gatherChunks(in folder: URL, prefix: String) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { $0.hasPrefix(prefix + "-") && $0.hasSuffix(".caf") }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    private func teardown(session: MeetingSession?, deleteFolder: Bool) async {
        micTap?.stop()
        systemTap?.stop()
        micTap = nil
        systemTap = nil
        _ = await micWriter?.close()
        _ = await systemWriter?.close()
        micWriter = nil
        systemWriter = nil
        micConsumerTask?.cancel()
        systemConsumerTask?.cancel()
        micConsumerTask = nil
        systemConsumerTask = nil
        removeSleepObserver()
        if deleteFolder, let session {
            try? FileManager.default.removeItem(at: session.folder)
        }
        self.session = nil
    }

    private func installSleepObserver() {
        removeSleepObserver()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main,
            using: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if case .recording = self.state {
                        logger.warning("System sleep detected — finalising meeting recording")
                        await self.finalise(reason: .sleepInterrupted)
                    }
                }
            }
        )
    }

    private func removeSleepObserver() {
        if let observer = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepObserver = nil
        }
    }
}
