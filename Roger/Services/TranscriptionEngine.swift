import Foundation
import os
import WhisperKit

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Transcription")

final class TranscriptionEngine: @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var currentModelName: String?

    var isReady: Bool {
        whisperKit != nil
    }

    /// Returns true if the loaded model matches the requested mode.
    func isReady(for mode: TranscriptionMode) -> Bool {
        guard whisperKit != nil else { return false }
        return currentModelName == mode.modelName
    }

    func setup(mode: TranscriptionMode, progressHandler: @Sendable @escaping (Double) -> Void) async throws {
        let modelName = mode.modelName
        logger.info("Setting up WhisperKit with model: \(modelName)")

        let config = WhisperKitConfig(
            model: modelName,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false
        )

        let pipe = try await WhisperKit(config)
        whisperKit = pipe
        currentModelName = modelName
        progressHandler(1.0)

        // Warmup: run a short silent transcription to trigger CoreML compilation
        // and Neural Engine loading. Without this, the first real transcription
        // takes 30-60s while the model compiles lazily.
        logger.info("Warming up model…")
        let silence = [Float](repeating: 0, count: Int(AudioCaptureService.targetSampleRate))
        let warmupOptions = DecodingOptions(
            language: "en",
            skipSpecialTokens: true,
            suppressBlank: true
        )
        _ = try? await pipe.transcribe(audioArray: silence, decodeOptions: warmupOptions)
        logger.info("WhisperKit ready with model: \(modelName)")
    }

    struct TranscriptionResult {
        let text: String
        let detectedLanguage: String?
    }

    func transcribe(audioBuffer: [Float], mode: TranscriptionMode) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionError.engineNotReady
        }

        let options = DecodingOptions(
            language: mode.whisperLanguage,
            detectLanguage: mode.whisperLanguage == nil, // auto-detect for multilingual
            skipSpecialTokens: true,
            suppressBlank: true
        )

        let results = try await whisperKit.transcribe(
            audioArray: audioBuffer,
            decodeOptions: options
        )

        let text = results
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract detected language from first result
        let detectedLanguage = results.first?.language

        logger.info("Transcribed \(text.count) characters, language: \(detectedLanguage ?? "unknown")")
        return TranscriptionResult(text: text, detectedLanguage: detectedLanguage)
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
