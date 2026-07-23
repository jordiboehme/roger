import Foundation
import FluidAudio
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingPipeline")

/// The shared meeting transcription pipeline: per-track ASR → optional
/// diarization (with the same flat fallbacks the finalisation always had) →
/// merge → per-paragraph post-processing. Used by finalisation (tracks as
/// m4a files) and by live screenshot checkpoints (tracks as samples read
/// from the CAF chunks mid-recording).
///
/// Per-track failures degrade instead of failing the run: a track that can't
/// be transcribed is logged and skipped, a failed diarization falls back to
/// flat speaker labels. The only throw is `CancellationError`, checked at
/// stage boundaries so a cancelled checkpoint job exits promptly.
struct MeetingTranscriptionPipeline: Sendable {
    let engine: TranscriptionEngine
    let diarization: DiarizationService

    struct Config: Sendable {
        let diarizeMic: Bool
        let diarizeSystem: Bool
        let languageOverride: String?
        let preset: DictationPreset
    }

    enum TrackSource: Sendable {
        case file(URL)
        case samples([Float])
        case absent
    }

    struct Output: Sendable {
        let paragraphs: [MeetingTranscriptMerger.Paragraph]
        let language: String?
        let diarizationFailed: Bool
    }

    /// `progress` spans 0-1 across all stages and may fire from any thread.
    func run(
        mic: TrackSource,
        system: TrackSource,
        config: Config,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Output {
        // Mic track — whichever path the result follows, we end up with a
        // `MeetingTranscriptMerger.MicInput`.
        var micInput: MeetingTranscriptMerger.MicInput = .none
        var micLanguage: String?
        var diarizationFailed = false

        if let detailed = try await transcribe(mic, config: config, trackName: "mic") {
            micLanguage = detailed.result.detectedLanguage
            progress?(0.25)
            if config.diarizeMic {
                do {
                    let segments = try await diarization.speakerSegments(
                        samples: detailed.audioSamples,
                        tokens: detailed.tokenTimings,
                        progress: { fraction in
                            progress?(0.25 + min(1, max(0, fraction)) * 0.25)
                        }
                    )
                    micInput = .diarized(segments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diarizationFailed = true
                    logger.warning("Mic diarization failed: \(error.localizedDescription, privacy: .public) — falling back to flat Me labels")
                    micInput = .flat(SpeakerAligner.segment(tokens: detailed.tokenTimings))
                }
            } else {
                micInput = .flat(SpeakerAligner.segment(tokens: detailed.tokenTimings))
            }
        }

        try Task.checkCancellation()
        progress?(0.5)

        // System track.
        var systemSpeakerSegments: [SpeakerSegment] = []
        var systemLanguage: String?

        if let detailed = try await transcribe(system, config: config, trackName: "system") {
            systemLanguage = detailed.result.detectedLanguage
            progress?(0.75)
            if config.diarizeSystem {
                do {
                    systemSpeakerSegments = try await diarization.speakerSegments(
                        samples: detailed.audioSamples,
                        tokens: detailed.tokenTimings,
                        progress: { fraction in
                            progress?(0.75 + min(1, max(0, fraction)) * 0.25)
                        }
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    diarizationFailed = true
                    logger.warning("System diarization failed: \(error.localizedDescription, privacy: .public)")
                    systemSpeakerSegments = Self.fallbackOtherSegments(tokens: detailed.tokenTimings)
                }
            } else {
                systemSpeakerSegments = Self.fallbackOtherSegments(tokens: detailed.tokenTimings)
            }
        }

        try Task.checkCancellation()

        // Merge + post-process. Cleanup runs per-paragraph so dedup and
        // filler removal stay scoped to a single speaker. AI steps are off by
        // construction (the meeting preset is guaranteed `requiresAI ==
        // false`), so `llmService: nil` is safe and stays fully on-device.
        let mergedParagraphs = MeetingTranscriptMerger.merge(
            mic: micInput,
            systemSpeakerSegments: systemSpeakerSegments
        )

        let resolvedLanguageCode = micLanguage ?? systemLanguage
        let languageHint: String = resolvedLanguageCode.map { WhisperLanguage.displayName(for: $0) }
            ?? "the original language"

        let postProcessor = PostProcessor()
        var paragraphs: [MeetingTranscriptMerger.Paragraph] = []
        for paragraph in mergedParagraphs {
            try Task.checkCancellation()
            let cleaned: String
            do {
                cleaned = try await postProcessor.process(
                    paragraph.text,
                    preset: config.preset,
                    language: languageHint,
                    llmService: nil
                )
            } catch {
                logger.warning("Paragraph post-processing failed (\(config.preset.name, privacy: .public)): \(error.localizedDescription, privacy: .public) — keeping raw text")
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

        progress?(1.0)
        return Output(
            paragraphs: paragraphs,
            language: resolvedLanguageCode,
            diarizationFailed: diarizationFailed
        )
    }

    /// ASR for one track. Nil when the track is absent or its transcription
    /// failed (logged) — the run continues with the other track.
    private func transcribe(
        _ source: TrackSource,
        config: Config,
        trackName: String
    ) async throws -> TranscriptionEngine.DetailedTranscriptionResult? {
        try Task.checkCancellation()
        do {
            switch source {
            case .absent:
                return nil
            case .file(let url):
                return try await engine.transcribeFileDetailed(
                    url: url,
                    languageOverride: config.languageOverride
                )
            case .samples(let samples):
                return try await engine.transcribeSamplesDetailed(
                    samples,
                    languageOverride: config.languageOverride
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("\(trackName, privacy: .public) transcription failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Builds a single-speaker ("S0") segment list from the ASR token timings
    /// so the merger labels the whole system track "Other 1" when diarization
    /// is off or failed.
    static func fallbackOtherSegments(tokens: [TokenTiming]) -> [SpeakerSegment] {
        SpeakerAligner.segment(tokens: tokens).map { seg in
            SpeakerSegment(speakerId: "S0", startTime: seg.startTime, endTime: seg.endTime, text: seg.text)
        }
    }
}
