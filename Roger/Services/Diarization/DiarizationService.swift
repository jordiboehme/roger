import Foundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Diarization")

/// Owns FluidAudio's `OfflineDiarizerManager` (pyannote segmentation +
/// WeSpeaker embeddings + PLDA scoring + VBx clustering, a non-Sendable class)
/// on a dedicated actor so diarization runs off the main thread and the CoreML
/// models load exactly once per launch.
///
/// The offline pipeline clusters speakers over the whole recording. The
/// windowed `DiarizerManager` Roger used before assigned speakers per 10 s
/// window and often renumbered the same voice at window edges (about 30 %
/// diarization error on FluidAudio's AMI benchmark against 12 % offline).
///
/// Anonymous clustering only — speakers come back as "S1", "S2" … with no
/// enrollment.
actor DiarizationService {
    private let engine = Engine()
    /// Tail of the call queue. `process` is async, so without it a second
    /// call could start on the same manager while the first is suspended.
    private var tail: Task<Void, Never>?

    /// Downloads (first use) and loads the diarization models. Safe to call
    /// repeatedly — work happens once.
    func prepare() async throws {
        try await enqueue { engine in try await engine.prepare() }
    }

    /// Clusters speakers over 16 kHz mono samples, returning time-ranged
    /// speaker segments. Loads models on first use. `progress` reports a
    /// 0-1 fraction once per processed segmentation chunk.
    func diarize(
        _ samples: [Float],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TimedSpeakerSegment] {
        try await enqueue { engine in
            try await engine.prepare()
            return try await engine.process(samples, progress: progress)
        }
    }

    /// Runs `work` after every earlier call has finished. Cancelling the
    /// caller cancels its own work.
    private func enqueue<T: Sendable>(
        _ work: @escaping @Sendable (Engine) async throws -> T
    ) async throws -> T {
        let previous = tail
        let engine = engine
        let task = Task<T, Error> {
            _ = await previous?.value
            try Task.checkCancellation()
            return try await work(engine)
        }
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The manager is not Sendable. The actor's queue guarantees one call at
    /// a time, which is what makes the unchecked conformance hold.
    private final class Engine: @unchecked Sendable {
        private let manager = OfflineDiarizerManager()
        private var ready = false

        func prepare() async throws {
            guard !ready else { return }
            try await manager.prepareModels()
            ready = true
            logger.info("Diarization models ready")
        }

        func process(_ samples: [Float], progress: (@Sendable (Double) -> Void)?) async throws -> [TimedSpeakerSegment] {
            let result = try await manager.process(audio: samples) { processed, total in
                guard total > 0 else { return }
                progress?(Double(processed) / Double(total))
            }
            return result.segments
        }
    }

    /// Diarizes `samples` and aligns the result against ASR `tokens`, returning
    /// Roger's speaker-attributed segments. Keeps FluidAudio's `TokenTiming` /
    /// `TimedSpeakerSegment` types out of the calling coordinators.
    func speakerSegments(
        samples: [Float],
        tokens: [TokenTiming],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerSegment] {
        let segments = try await diarize(samples, progress: progress)
        return SpeakerAligner.align(tokens: tokens, diarization: segments)
    }
}
