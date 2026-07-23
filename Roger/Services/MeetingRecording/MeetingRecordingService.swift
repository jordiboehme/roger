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

    // Screenshot checkpoints — see addCheckpoint(image:droppedAt:).
    private(set) var checkpointCount = 0
    private(set) var pendingCheckpointTranscriptions = 0
    private(set) var lastCheckpointAt: Date?
    private var checkpointStore: MeetingCheckpointStore?
    private var checkpointChain: Task<Void, Never>?
    private var checkpointTasks: [Task<Void, Never>] = []

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
        checkpointStore = MeetingCheckpointStore(folder: session.folder, sessionStartedAt: session.startedAt)
        checkpointCount = 0
        pendingCheckpointTranscriptions = 0
        lastCheckpointAt = nil

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
            // markers.json (written on every screenshot drop) carries the
            // exact session start; the folder creation date is the fallback.
            let started = MeetingCheckpointStore.load(from: url)?.sessionStartedAt
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? Date()
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

    // MARK: - Screenshot Checkpoints

    /// Saves a dropped screenshot into the session folder and records a
    /// durable marker immediately; the cumulative transcription that produces
    /// the provisional segment md is queued behind any in-flight checkpoint
    /// job. No-op unless recording. Synchronous on purpose: no suspension
    /// between the state guard and the marker write, so rapid drops stay
    /// strictly ordered by main-actor execution.
    func addCheckpoint(image: MeetingCheckpointImage, droppedAt: Date) {
        guard case .recording = state, let session, let store = checkpointStore else {
            logger.info("Screenshot drop ignored — no active meeting recording")
            cleanupDroppedImage(image)
            return
        }

        let fileExtension: String
        switch image {
        case .file(let url, _):
            let ext = url.pathExtension.lowercased()
            fileExtension = ext.isEmpty ? "png" : ext
        case .pngData:
            fileExtension = "png"
        }

        let marker = store.makeMarker(capturedAt: droppedAt, fileExtension: fileExtension)
        let destination = session.folder.appendingPathComponent(marker.imageFile)

        do {
            switch image {
            case .file(let url, let deleteAfterCopy):
                try FileManager.default.copyItem(at: url, to: destination)
                if deleteAfterCopy {
                    try? FileManager.default.removeItem(at: url)
                }
            case .pngData(let data):
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            logger.error("Failed to save screenshot: \(error.localizedDescription, privacy: .public)")
            return
        }

        do {
            try store.append(marker)
        } catch {
            logger.error("Failed to persist checkpoint marker: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return
        }

        checkpointCount += 1
        lastCheckpointAt = Date()
        pendingCheckpointTranscriptions += 1

        let context = store.chunkContext(for: marker)
        let config = currentPipelineConfig()
        let previousChain = checkpointChain
        let job = Task { [weak self] in
            await previousChain?.value
            guard let self else { return }
            await self.performCheckpointTranscription(
                marker: marker,
                chunkStart: context.chunkStart,
                previousOffset: context.previousOffset,
                config: config
            )
        }
        checkpointChain = job
        checkpointTasks.append(job)
        logger.notice("Checkpoint \(self.checkpointCount) recorded: \(marker.imageFile, privacy: .public)")
    }

    /// One serialized checkpoint job: force-roll both writers so all audio up
    /// to now sits in closed CAF chunks, read them back, run the cumulative
    /// pipeline from the session start (diarization over the full prefix
    /// keeps Other N numbering stable across segments) and write only the
    /// paragraphs in this marker's range as a provisional segment md. Errors
    /// never disturb the recording — the marker and screenshot stand, and
    /// finalisation rewrites every segment authoritatively anyway.
    private func performCheckpointTranscription(
        marker: MeetingCheckpointMarker,
        chunkStart: Date,
        previousOffset: Double,
        config: MeetingTranscriptionPipeline.Config
    ) async {
        defer { pendingCheckpointTranscriptions -= 1 }
        guard !Task.isCancelled else { return }
        guard case .recording = state, let session else { return }
        guard transcriptionEngine.isReady else {
            logger.warning("Checkpoint transcription skipped — speech model not loaded")
            return
        }

        // Rolling inside the job (not at drop time) is safe: it happens at or
        // after the marker moment, so the chunks contain all audio up to the
        // marker plus possibly a bit beyond — the range filter below discards
        // the excess.
        let micChunks = await micWriter?.rollSegment() ?? []
        let systemChunks = await systemWriter?.rollSegment() ?? []

        let micRead = Task.detached(priority: .utility) {
            AudioChunkSampleReader.samples(from: micChunks)
        }
        let systemRead = Task.detached(priority: .utility) {
            AudioChunkSampleReader.samples(from: systemChunks)
        }
        let micSamples = await micRead.value
        let systemSamples = await systemRead.value

        // Under a second of audio isn't worth a pipeline run.
        let minSamples = Int(SystemAudioTap.targetSampleRate)
        let mic: MeetingTranscriptionPipeline.TrackSource =
            micSamples.count >= minSamples ? .samples(micSamples) : .absent
        let system: MeetingTranscriptionPipeline.TrackSource =
            systemSamples.count >= minSamples ? .samples(systemSamples) : .absent
        if case .absent = mic, case .absent = system { return }

        let output: MeetingTranscriptionPipeline.Output
        do {
            output = try await transcriptionPipeline().run(mic: mic, system: system, config: config)
        } catch {
            // Only CancellationError reaches here — stop was requested and
            // finalisation takes over.
            return
        }

        let segmentParagraphs = output.paragraphs.filter {
            Double($0.startTime) >= previousOffset && Double($0.startTime) < marker.offsetSeconds
        }
        do {
            try MeetingSegmentWriter.write(
                paragraphs: segmentParagraphs,
                sessionStartedAt: session.startedAt,
                chunkStart: chunkStart,
                folder: session.folder,
                provisional: true
            )
        } catch {
            logger.warning("Provisional segment write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancels every queued and in-flight checkpoint job, then waits for them
    /// to settle. Must run before finalisation or teardown: a straggler would
    /// race the CAF chunk deletion and could overwrite authoritative segment
    /// files. Worst case this waits for the current pipeline stage to notice
    /// the cancellation — Parakeet on the ANE is much faster than real time.
    private func drainCheckpointJobs() async {
        guard !checkpointTasks.isEmpty else { return }
        for task in checkpointTasks { task.cancel() }
        for task in checkpointTasks { _ = await task.value }
        checkpointTasks = []
        checkpointChain = nil
        pendingCheckpointTranscriptions = 0
    }

    /// Deletes a promised temp file when a drop is ignored so temp folders
    /// don't accumulate.
    private func cleanupDroppedImage(_ image: MeetingCheckpointImage) {
        if case .file(let url, true) = image {
            try? FileManager.default.removeItem(at: url)
        }
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
        // Settle checkpoint jobs before anything else — they read CAF chunks
        // and write segment files, both of which finalisation owns from here.
        await drainCheckpointJobs()
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

    /// Raises finalisation progress, never lowers it — late async progress
    /// callbacks must not rewind the bar past a milestone already set.
    private func bumpFinalisingProgress(to value: Double) {
        if case .finalising(let current) = state, value > current {
            state = .finalising(progress: value)
        }
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

        // The shared pipeline handles ASR, diarization, merge and
        // post-processing for both finalisation and live checkpoints.
        // Finalisation is never cancelled, so the only throw the pipeline
        // can produce (CancellationError) is a defensive catch here.
        let output: MeetingTranscriptionPipeline.Output
        do {
            output = try await transcriptionPipeline().run(
                mic: micPresent ? .file(micArchive) : .absent,
                system: systemPresent ? .file(systemArchive) : .absent,
                config: currentPipelineConfig(),
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.bumpFinalisingProgress(to: 0.45 + min(1, max(0, fraction)) * 0.40)
                    }
                }
            )
        } catch {
            state = .error(.finalisationFailed(error.localizedDescription))
            lastSession = session
            return
        }

        state = .finalising(progress: 0.85)
        let paragraphs = output.paragraphs

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
            language: output.language,
            micPresent: micPresent,
            systemPresent: systemPresent,
            diarizationFailed: output.diarizationFailed,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            modelDescription: "Parakeet TDT v3"
        )

        // Screenshot checkpoints: rewrite every segment md from this
        // authoritative full pass (overwriting the provisional live ones)
        // and weave inline image references into transcript.md. `load`
        // covers crash and sleep recovery, where the live store is gone.
        let checkpointFile = checkpointStore?.file ?? MeetingCheckpointStore.load(from: session.folder)
        let markers = checkpointFile?.markers ?? []
        if !markers.isEmpty {
            let effectiveStart = checkpointFile?.sessionStartedAt ?? session.startedAt
            for chunk in MeetingCheckpointStore.chunks(sessionStartedAt: effectiveStart, markers: markers) {
                let segmentParagraphs = paragraphs.filter { chunk.range.contains(Double($0.startTime)) }
                guard !segmentParagraphs.isEmpty else {
                    MeetingSegmentWriter.removeIfExists(chunkStart: chunk.start, folder: session.folder)
                    continue
                }
                do {
                    try MeetingSegmentWriter.write(
                        paragraphs: segmentParagraphs,
                        sessionStartedAt: effectiveStart,
                        chunkStart: chunk.start,
                        folder: session.folder,
                        provisional: false
                    )
                } catch {
                    logger.warning("Segment write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        do {
            _ = try MeetingTranscriptWriter.write(paragraphs: paragraphs, metadata: metadata, markers: markers)
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
        checkpointStore = nil
        logger.notice("Meeting recording finalised at \(session.folder.path, privacy: .public)")
    }

    private func transcriptionPipeline() -> MeetingTranscriptionPipeline {
        MeetingTranscriptionPipeline(engine: transcriptionEngine, diarization: diarization)
    }

    /// Snapshot of the settings the pipeline needs. Taken at call time so a
    /// checkpoint job and the finalisation each run with the settings that
    /// were current when they were queued.
    ///
    /// `meetingTranscriptionPreset` is guaranteed to have no AI steps;
    /// `resolvedLanguage` enforces the model-vs-preset precedence (the
    /// English-only model always wins, matching the existing behaviour in
    /// PresetsSettingsView's mismatch warning).
    private func currentPipelineConfig() -> MeetingTranscriptionPipeline.Config {
        let preset = appState.meetingTranscriptionPreset
        return MeetingTranscriptionPipeline.Config(
            diarizeMic: appState.meetingDiarizeMic,
            diarizeSystem: appState.meetingDiarizeSystem,
            languageOverride: appState.resolvedLanguage(for: preset),
            preset: preset
        )
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
        await drainCheckpointJobs()
        checkpointStore = nil
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
