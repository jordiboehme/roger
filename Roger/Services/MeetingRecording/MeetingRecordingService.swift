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

        let startedAt = Date()
        let parent = appState.libraryLayout.monthFolder(.meetings, for: startedAt)
        let session: MeetingSession
        do {
            session = try MeetingSession.create(in: parent, startedAt: startedAt)
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

    /// Recovery scan: finds session folders that have no transcript.md but
    /// still hold audio (CAF chunks after a crash mid-recording, or
    /// mic.m4a/system.m4a after a finalisation that stopped before the
    /// transcript). Caller can prompt the user, then call `finaliseRecovered(_:)`.
    func unfinalisedSessions() -> [MeetingSession] {
        let folders = MeetingSessionScanner.allSessionFolders(
            layout: appState.libraryLayout,
            extraFolders: appState.extraScanFolders
        )
        var result: [MeetingSession] = []
        for url in folders where MeetingSessionScanner.isUnfinished(url) {
            // markers.json (written on every screenshot drop) carries the
            // exact session start; the folder creation date is the fallback.
            let started = MeetingCheckpointStore.load(from: url)?.sessionStartedAt
                ?? LibraryMigration.sessionDate(for: url)
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? Date()
            result.append(MeetingSession(id: MeetingSession.stableID(for: url), folder: url, startedAt: started))
        }
        return result
    }

    /// Re-runs concatenation + transcription against an existing session
    /// folder. Tracks without CAF chunks use their existing archive.
    func finaliseRecovered(_ session: MeetingSession) async {
        guard !isActive else {
            logger.warning("Recovery requested while a session is active — ignored")
            return
        }
        self.session = session
        // A live store left over from an earlier session must not lend its
        // markers or start time to this one; the pipeline loads the
        // session's own markers.json instead.
        checkpointStore = nil
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
            output = try await transcriptionPipeline().run(
                mic: mic,
                system: system,
                config: config,
                breaks: [previousOffset, marker.offsetSeconds]
            )
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
                chunkEnd: session.startedAt.addingTimeInterval(marker.offsetSeconds),
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

        // Without chunks, a retry after an earlier run that encoded the
        // archives but stopped before the transcript reuses those archives.
        // A reused archive is never re-encoded, overwritten or deleted.
        let micSource = MeetingTrackSource.resolve(chunks: micSegments, archive: micArchive)
        let systemSource = MeetingTrackSource.resolve(chunks: systemSegments, archive: systemArchive)
        if micSource == .existingArchive { logger.notice("No mic chunks, using existing mic.m4a") }
        if systemSource == .existingArchive { logger.notice("No system chunks, using existing system.m4a") }
        // An archive that existed before this run may be the only copy of
        // that audio: it is never overwritten (see `encodeTrack`) or deleted.
        let micPreexisting = FileManager.default.fileExists(atPath: micArchive.path)
        let systemPreexisting = FileManager.default.fileExists(atPath: systemArchive.path)

        var micOutcome: MeetingTrackEncodeOutcome?
        var systemOutcome: MeetingTrackEncodeOutcome?
        var micEncodedLanded = false
        var systemEncodedLanded = false
        var micLeftoverKept = false
        var systemLeftoverKept = false

        if !micSegments.isEmpty {
            do {
                let encoded = try await encodeTrack(micSegments, into: micArchive)
                micOutcome = .encoded(encoded.result)
                micEncodedLanded = encoded.landed
                micLeftoverKept = encoded.leftoverKept
            } catch {
                logger.error("Mic encode failed: \(error.localizedDescription, privacy: .public)")
                failFinalisation("Mic encode failed: \(error.localizedDescription)", session: session)
                return
            }
        }
        state = .finalising(progress: 0.30)
        if !systemSegments.isEmpty {
            do {
                let encoded = try await encodeTrack(systemSegments, into: systemArchive)
                systemOutcome = .encoded(encoded.result)
                systemEncodedLanded = encoded.landed
                systemLeftoverKept = encoded.leftoverKept
            } catch {
                // System-side encode failures should NOT block the rest of
                // the pipeline — the mic transcript is still useful. Log
                // loudly, keep the chunks, and continue.
                logger.error("System encode failed (continuing without new system audio, chunks kept): \(error.localizedDescription, privacy: .public)")
                systemOutcome = .failed
            }
        }

        // Delete only chunks whose audio is in the archive, plus empty ones.
        // Unreadable chunks, and all chunks after a failed encode, stay on
        // disk so the audio is not lost.
        let micDeletable = micOutcome?.deletableChunks(archiveExists: micEncodedLanded) ?? []
        for url in micDeletable { try? FileManager.default.removeItem(at: url) }
        let systemDeletable = systemOutcome?.deletableChunks(archiveExists: systemEncodedLanded) ?? []
        for url in systemDeletable { try? FileManager.default.removeItem(at: url) }

        // A track is present when its archive is on disk: freshly encoded,
        // reused from an earlier run, or kept as the longer file.
        let micPresent = FileManager.default.fileExists(atPath: micArchive.path)
        let systemPresent = FileManager.default.fileExists(atPath: systemArchive.path)
        // Also true when the archive was written without some unreadable
        // chunks: the chunks were kept and the session is offered again.
        // A leftover file kept beside the archive also means the transcript
        // does not cover all audio of that track.
        let micAudioFailed = (micOutcome?.needsRetry ?? false) || micLeftoverKept
        let systemAudioFailed = (systemOutcome?.needsRetry ?? false) || systemLeftoverKept

        guard transcriptionEngine.isReady else {
            // Audio is on disk; transcription can be retried later. Surface
            // an error so the user knows the .md isn't there yet.
            failFinalisation("Speech model isn't loaded. Audio saved, try again from the menu bar.", session: session)
            return
        }

        state = .finalising(progress: 0.45)

        // The shared pipeline handles ASR, diarization, merge and
        // post-processing for both finalisation and live checkpoints.
        // Finalisation is never cancelled, so the only throw the pipeline
        // can produce (CancellationError) is a defensive catch here.
        let finalConfig = currentPipelineConfig()
        // `load` covers crash and sleep recovery, where the live store is gone.
        let checkpointFile = checkpointStore?.file ?? MeetingCheckpointStore.load(from: session.folder)
        let markers = checkpointFile?.markers ?? []
        let output: MeetingTranscriptionPipeline.Output
        do {
            output = try await transcriptionPipeline().run(
                mic: micPresent ? .file(micArchive) : .absent,
                system: systemPresent ? .file(systemArchive) : .absent,
                config: finalConfig,
                breaks: markers.map(\.offsetSeconds),
                progress: { [weak self] fraction in
                    Task { @MainActor in
                        self?.bumpFinalisingProgress(to: 0.45 + min(1, max(0, fraction)) * 0.40)
                    }
                }
            )
        } catch {
            failFinalisation(error.localizedDescription, session: session)
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
        // Keep all audio when an archive existed before this run (it may be
        // the only copy) or when a track failed (a retry needs the other
        // track's archive). The transcript then lists exactly the files that
        // stay on disk.
        let audioKept = appState.keepMeetingAudio || micPreexisting || systemPreexisting
            || micAudioFailed || systemAudioFailed
        let metadata = MeetingTranscriptWriter.Metadata(
            session: session,
            durationSeconds: durationSeconds,
            speakerCount: speakerCount,
            language: output.language,
            micPresent: micPresent,
            systemPresent: systemPresent,
            audioKept: audioKept,
            diarized: (micPresent && finalConfig.diarizeMic) || (systemPresent && finalConfig.diarizeSystem),
            diarizationFailed: output.diarizationFailed,
            micAudioFailed: micAudioFailed,
            systemAudioFailed: systemAudioFailed
        )

        // Screenshot checkpoints: rewrite every segment md from this
        // authoritative full pass (overwriting the provisional live ones)
        // and weave inline image references into transcript.md.
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
                        chunkEnd: effectiveStart.addingTimeInterval(
                            chunk.range.upperBound.isFinite ? chunk.range.upperBound : Double(durationSeconds)
                        ),
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
            failFinalisation(error.localizedDescription, session: session)
            return
        }

        if !audioKept, !paragraphs.isEmpty {
            // Only after the transcript exists: the CAF chunks are already gone,
            // so these archives were the last copy of the audio.
            try? FileManager.default.removeItem(at: micArchive)
            try? FileManager.default.removeItem(at: systemArchive)
        }

        if micAudioFailed || systemAudioFailed {
            // The transcript lacks a track; its chunks were kept and the
            // session shows up again for a retry.
            state = .error(.trackAudioFailed(mic: micAudioFailed, system: systemAudioFailed))
        } else if sleepInterrupted {
            state = .error(.sleepInterrupted)
        } else {
            state = .idle
        }
        lastSession = session
        self.session = nil
        checkpointStore = nil
        logger.notice("Meeting recording finalised at \(session.folder.path, privacy: .public)")
    }

    /// Encodes `segments` into `archive`. When `archive` already exists
    /// (chunks left over next to a finished archive), the chunks go to a side
    /// file instead and `MeetingArchiveMerge` keeps the longer of the two as
    /// the archive; neither file is overwritten or deleted. `landed` is true
    /// when the encoded audio is on disk. `leftoverKept` is true when the
    /// new encode stays beside the archive as a side file, so the archive
    /// (and the transcript) does not have all of the audio.
    private func encodeTrack(
        _ segments: [URL],
        into archive: URL
    ) async throws -> (result: AudioSegmentConcatenator.Result, landed: Bool, leftoverKept: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archive.path) else {
            let result = try await AudioSegmentConcatenator.concatenate(segments: segments, destinationURL: archive)
            return (result, fm.fileExists(atPath: archive.path), false)
        }
        let side = MeetingArchiveMerge.leftoverURL(for: archive)
        let result = try await AudioSegmentConcatenator.concatenate(segments: segments, destinationURL: side)
        guard result.wrote, fm.fileExists(atPath: side.path) else { return (result, false, false) }
        let keepEncoded = await audioSeconds(side) > audioSeconds(archive)
        try MeetingArchiveMerge.settle(archive: archive, encoded: side, keepEncoded: keepEncoded)
        if keepEncoded {
            logger.warning("Chunks next to \(archive.lastPathComponent, privacy: .public): the new encode is longer and became the archive, the old one was moved aside")
        } else {
            logger.warning("Chunks next to \(archive.lastPathComponent, privacy: .public): kept the existing archive, the new encode stays beside it as \(side.lastPathComponent, privacy: .public)")
        }
        return (result, true, !keepEncoded)
    }

    private func audioSeconds(_ url: URL) async -> Double {
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }

    /// Ends a finalisation run with an error. Drops the live checkpoint
    /// store so no state leaks into a later retry of another session; the
    /// markers stay on disk in markers.json.
    private func failFinalisation(_ reason: String, session: MeetingSession) {
        state = .error(.finalisationFailed(reason))
        lastSession = session
        checkpointStore = nil
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
