import CoreAudio
import Foundation
import os
import WhisperKit

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Transcription")

final class TranscriptionEngine: @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var currentModelName: String?
    private var streamTranscriber: AudioStreamTranscriber?
    private var streamLoopTask: Task<Void, Never>?
    private let latestStreamSnapshot = OSAllocatedUnfairLock<StreamSnapshot?>(initialState: nil)

    private struct StreamSnapshot: Sendable {
        var confirmedSegments: [TranscriptionSegment]
        var unconfirmedSegments: [TranscriptionSegment]
    }

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

    // MARK: - Streaming Transcription

    /// True while a streaming session is running.
    var isStreaming: Bool {
        streamTranscriber != nil
    }

    /// Starts a streaming transcription session. WhisperKit's own AudioProcessor
    /// takes ownership of the microphone (via AVAudioEngine) and runs a 100 ms
    /// transcription loop in the background. Use `finishStreaming` to stop and
    /// harvest the final text.
    func startStreaming(mode: TranscriptionMode, inputDeviceID: AudioDeviceID?) async throws {
        guard let whisperKit else {
            throw TranscriptionError.engineNotReady
        }
        guard let tokenizer = whisperKit.tokenizer else {
            throw TranscriptionError.engineNotReady
        }
        guard streamTranscriber == nil else {
            logger.warning("startStreaming called while another stream is active — ignoring")
            return
        }

        latestStreamSnapshot.withLock { $0 = nil }

        let options = DecodingOptions(
            language: mode.whisperLanguage,
            detectLanguage: mode.whisperLanguage == nil,
            skipSpecialTokens: true,
            suppressBlank: true
        )

        // Capture a latest-state snapshot via the actor's state callback so we
        // can read the final segments after stopping without crossing the
        // actor boundary twice.
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            useVAD: false,
            stateChangeCallback: { [weak self] _, newState in
                self?.storeStreamState(newState)
            }
        )
        streamTranscriber = transcriber

        // Tell WhisperKit's AudioProcessor to use the caller-chosen device.
        // The AudioStreamTranscriber internally calls startRecordingLive()
        // with no device argument, so pre-assign by starting and stopping once
        // — instead, we wire device selection via setInputDevice when available.
        // For now WhisperKit's default (system-default input) is what the user
        // gets during streaming; explicit device selection is a follow-up.
        _ = inputDeviceID

        streamLoopTask = Task.detached {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                logger.error("Streaming transcription loop failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops a streaming session and returns the combined text from all
    /// confirmed and unconfirmed segments.
    func finishStreaming() async throws -> TranscriptionResult {
        guard let transcriber = streamTranscriber else {
            throw TranscriptionError.engineNotReady
        }

        await transcriber.stopStreamTranscription()
        streamLoopTask?.cancel()
        streamLoopTask = nil
        streamTranscriber = nil

        let snapshot = latestStreamSnapshot.withLock { value -> StreamSnapshot? in
            let snap = value
            value = nil
            return snap
        }

        let confirmedSegments = snapshot?.confirmedSegments ?? []
        let unconfirmedSegments = snapshot?.unconfirmedSegments ?? []
        let segments = confirmedSegments + unconfirmedSegments
        let text = segments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        logger.notice("Streaming finished: \(text.count) chars (\(confirmedSegments.count) confirmed + \(unconfirmedSegments.count) unconfirmed segments)")
        return TranscriptionResult(text: text, detectedLanguage: nil)
    }

    /// Cancels a streaming session without harvesting results.
    func cancelStreaming() async {
        guard let transcriber = streamTranscriber else { return }
        await transcriber.stopStreamTranscription()
        streamLoopTask?.cancel()
        streamLoopTask = nil
        streamTranscriber = nil
        latestStreamSnapshot.withLock { $0 = nil }
    }

    private func storeStreamState(_ state: AudioStreamTranscriber.State) {
        let snapshot = StreamSnapshot(
            confirmedSegments: state.confirmedSegments,
            unconfirmedSegments: state.unconfirmedSegments
        )
        latestStreamSnapshot.withLock { $0 = snapshot }
    }

    // MARK: - Batch Transcription

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

        logger.notice("Transcribed \(text.count) characters, language: \(detectedLanguage ?? "unknown")")
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
