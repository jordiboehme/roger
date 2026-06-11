import Foundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Diarization")

/// Owns FluidAudio's `DiarizerManager` (a non-Sendable, synchronous class) on a
/// dedicated actor so diarization runs off the main thread and the pyannote +
/// WeSpeaker CoreML models load exactly once per launch.
///
/// Anonymous clustering only — speakers come back as "S1", "S2" … with no
/// enrollment, matching the behaviour Roger had with SpeakerKit.
actor DiarizationService {
    private let manager = DiarizerManager()
    private var ready = false

    /// Downloads (first launch) and loads the diarization models. Safe to call
    /// repeatedly — work happens once.
    func prepare() async throws {
        guard !ready else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        manager.initialize(models: models)
        ready = true
        logger.info("Diarization models ready")
    }

    /// Clusters speakers over 16 kHz mono samples, returning time-ranged
    /// speaker segments. Loads models on first use.
    func diarize(_ samples: [Float]) async throws -> [TimedSpeakerSegment] {
        try await prepare()
        return try manager.performCompleteDiarization(samples, sampleRate: 16000).segments
    }

    /// Diarizes `samples` and aligns the result against ASR `tokens`, returning
    /// Roger's speaker-attributed segments. Keeps FluidAudio's `TokenTiming` /
    /// `TimedSpeakerSegment` types out of the calling coordinators.
    func speakerSegments(samples: [Float], tokens: [TokenTiming]) async throws -> [SpeakerSegment] {
        let segments = try await diarize(samples)
        return SpeakerAligner.align(tokens: tokens, diarization: segments)
    }
}
