import AVFoundation
import Foundation
import FluidAudio
import NaturalLanguage
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Transcription")

/// User-facing snapshot of model download/compile progress. Mapped from
/// FluidAudio's `DownloadProgress` here so coordinators and views never
/// see FluidAudio types.
struct ModelSetupProgress: Sendable, Equatable {
    let fraction: Double
    let stage: String
}

/// On-device speech-to-text via FluidAudio's Parakeet Ultra (CoreML, runs on
/// the Apple Neural Engine). Transcription is batch: the caller captures the
/// whole audio buffer and hands it over on stop. `AsrManager` is an actor, so
/// this is a thin lifecycle wrapper that maps Roger's language pin to Parakeet's
/// optional `Language` script hint.
final class TranscriptionEngine: @unchecked Sendable {
    /// Set once during `setup`, then read-only — single-writer-before-use, same
    /// ownership discipline the previous WhisperKit wrapper relied on.
    private var asrManager: AsrManager?

    struct TranscriptionResult: Sendable {
        let text: String
        let detectedLanguage: String?
    }

    /// Returned by `transcribeFileDetailed` — carries the ASR token timings and
    /// the decoded audio so the caller can run diarization without re-loading
    /// or re-transcribing the file.
    struct DetailedTranscriptionResult: Sendable {
        let result: TranscriptionResult
        let tokenTimings: [TokenTiming]
        let audioSamples: [Float]
    }

    var isReady: Bool { asrManager != nil }

    /// The single multilingual model Roger uses: Parakeet Ultra, a post-trained
    /// v3 with the same 25 languages, tokenizer and speed but lower error rates.
    static let modelVersion: AsrModelVersion = .ultra
    static let modelName = "Parakeet Ultra"

    /// Models earlier Roger versions downloaded. Removed once the current model
    /// is loaded, so an upgrade never leaves an unused ~480 MB bundle behind.
    private static let legacyModelVersions: [AsrModelVersion] = [.v3]

    /// Downloads (first launch) and loads Parakeet Ultra. `melChunkContext:
    /// false` is the recommended setting for v3-family multilingual long-form
    /// audio (avoids an English-bias drift at chunk boundaries on e.g. German
    /// meeting audio).
    func setup(progressHandler: @Sendable @escaping (ModelSetupProgress) -> Void) async throws {
        guard asrManager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: Self.modelVersion) { progress in
            progressHandler(ModelSetupProgress(
                fraction: progress.fractionCompleted,
                stage: Self.stageDescription(for: progress.phase)
            ))
        }
        asrManager = AsrManager(config: ASRConfig(melChunkContext: false), models: models)
        logger.info("\(Self.modelName, privacy: .public) ready")
        Self.removeLegacyModels()
    }

    /// Deletes caches of models Roger no longer uses. Only called after the
    /// current model loaded, so a failed download never costs the old one.
    private static func removeLegacyModels() {
        let current = AsrModels.defaultCacheDirectory(for: modelVersion).standardizedFileURL
        for version in legacyModelVersions {
            let dir = AsrModels.defaultCacheDirectory(for: version).standardizedFileURL
            guard dir != current, FileManager.default.fileExists(atPath: dir.path) else { continue }
            do {
                try FileManager.default.removeItem(at: dir)
                logger.notice("Removed legacy model at \(dir.path, privacy: .public)")
            } catch {
                logger.error("Failed to remove legacy model at \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// FluidAudio's fraction already spans download (0-0.5) and CoreML
    /// compilation (0.5-1.0), so the stage label is the only mapping needed.
    private static func stageDescription(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Preparing download…"
        case .downloading(let completed, let total):
            return "Downloading model - file \(min(completed + 1, max(total, 1))) of \(total)"
        case .compiling:
            return "Optimizing for Neural Engine…"
        }
    }

    func uninstall() async {
        asrManager = nil
        let dir = AsrModels.defaultCacheDirectory(for: Self.modelVersion)
        try? FileManager.default.removeItem(at: dir)
        logger.info("Parakeet model removed from \(dir.path, privacy: .public)")
        Self.removeLegacyModels()
    }

    // MARK: - Transcription

    /// Transcribes a captured 16 kHz mono buffer (dictation, batch-on-release).
    func transcribe(audioBuffer: [Float], languageOverride: String?) async throws -> TranscriptionResult {
        guard let asrManager else { throw TranscriptionError.engineNotReady }
        var state = try TdtDecoderState()
        let result = try await asrManager.transcribe(
            audioBuffer,
            decoderState: &state,
            language: Self.languageHint(languageOverride)
        )
        return Self.makeResult(from: result, languageOverride: languageOverride)
    }

    /// Transcribes an audio file directly (menu-bar drag-and-drop). FluidAudio
    /// chunks the samples internally.
    func transcribeFile(url: URL, languageOverride: String?) async throws -> TranscriptionResult {
        guard let asrManager else { throw TranscriptionError.engineNotReady }
        // Load through Roger's tolerant reader rather than handing FluidAudio
        // the URL: its reader stops silently at the first mid-file decode error.
        let samples = try AudioFileLoader.load16kMono(url)
        var state = try TdtDecoderState()
        let result = try await asrManager.transcribe(
            samples,
            decoderState: &state,
            language: Self.languageHint(languageOverride)
        )
        return Self.makeResult(from: result, languageOverride: languageOverride)
    }

    /// Transcribes a file and returns token timings + decoded samples so the
    /// caller can diarize (file transcription, meeting tracks) off the same data.
    func transcribeFileDetailed(url: URL, languageOverride: String?) async throws -> DetailedTranscriptionResult {
        let samples = try AudioFileLoader.load16kMono(url)
        return try await transcribeSamplesDetailed(samples, languageOverride: languageOverride)
    }

    /// Same as `transcribeFileDetailed` for callers that assembled the 16 kHz
    /// mono samples themselves (meeting checkpoints reading CAF chunks
    /// mid-recording).
    func transcribeSamplesDetailed(_ samples: [Float], languageOverride: String?) async throws -> DetailedTranscriptionResult {
        guard let asrManager else { throw TranscriptionError.engineNotReady }
        var state = try TdtDecoderState()
        let result = try await asrManager.transcribe(
            samples,
            decoderState: &state,
            language: Self.languageHint(languageOverride)
        )
        return DetailedTranscriptionResult(
            result: Self.makeResult(from: result, languageOverride: languageOverride),
            tokenTimings: result.tokenTimings ?? [],
            audioSamples: samples
        )
    }

    // MARK: - Helpers

    private static func makeResult(from result: ASRResult, languageOverride: String?) -> TranscriptionResult {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: text,
            detectedLanguage: resolveLanguage(override: languageOverride, text: text)
        )
    }

    /// Maps Roger's ISO-639-1 language pin to Parakeet's optional script hint.
    /// `nil` (multilingual / auto) leaves the model to detect across all 25 languages.
    private static func languageHint(_ code: String?) -> Language? {
        guard let code else { return nil }
        return Language(rawValue: code)
    }

    /// Parakeet doesn't emit a detected-language tag. If the pin forced one we
    /// already know it; otherwise detect locally from the output text.
    private static func resolveLanguage(override: String?, text: String) -> String? {
        if let override { return override }
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

enum TranscriptionError: LocalizedError {
    case engineNotReady

    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Speech recognition model not loaded. Check Settings to download it."
        }
    }
}
