import Foundation
import os
import WhisperKit

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Transcription")

final class TranscriptionEngine: @unchecked Sendable {
    private var whisperKit: WhisperKit?

    var isReady: Bool {
        whisperKit != nil
    }

    func setup(progressHandler: @Sendable @escaping (Double) -> Void) async throws {
        logger.info("Setting up WhisperKit…")

        // Let WhisperKit pick the best model for this device.
        // Do NOT hardcode distil-large-v3 — it's English-only.
        // WhisperKit auto-selects a multilingual model (e.g. large-v3-turbo).
        let recommended = WhisperKit.recommendedModels()
        let modelName = recommended.default
        logger.info("Using model: \(modelName)")

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
        progressHandler(1.0)

        logger.info("WhisperKit ready")
    }

    func transcribe(audioBuffer: [Float], language: Language) async throws -> String {
        guard let whisperKit else {
            throw TranscriptionError.engineNotReady
        }

        let options = DecodingOptions(
            language: language.rawValue,
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

        logger.info("Transcribed \(text.count) characters")
        return text
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
