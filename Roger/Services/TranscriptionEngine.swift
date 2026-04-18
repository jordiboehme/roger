import AVFoundation
import CoreAudio
import CoreML
import Foundation
import NaturalLanguage
import os
import WhisperKit

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Transcription")

final class TranscriptionEngine: @unchecked Sendable {
    private var whisperKit: WhisperKit?
    private var currentModelName: String?
    private var streamTranscriber: AudioStreamTranscriber?
    private var streamLoopTask: Task<Void, Never>?
    private var streamMode: TranscriptionMode?
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

    /// Starts a streaming transcription session. A `DevicePinnedAudioProcessor`
    /// wraps WhisperKit's `AudioProcessor` so the user's selected input device
    /// is honored while WhisperKit's `AudioStreamTranscriber` actor runs its
    /// 100 ms transcription loop in the background. Use `finishStreaming` to
    /// stop and harvest the final text.
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

        // Pin the user's selected input device into the AudioProcessor so
        // AudioStreamTranscriber's own startRecordingLive() call routes to it.
        let audioProcessor: any AudioProcessing
        if let deviceID = inputDeviceID {
            audioProcessor = DevicePinnedAudioProcessor(deviceID: deviceID)
            logger.info("Streaming with pinned input device \(deviceID)")
        } else {
            audioProcessor = whisperKit.audioProcessor
        }

        // Capture a latest-state snapshot via the actor's state callback so we
        // can read the final segments after stopping without crossing the
        // actor boundary twice.
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: audioProcessor,
            decodingOptions: options,
            useVAD: false,
            stateChangeCallback: { [weak self] _, newState in
                self?.storeStreamState(newState)
            }
        )
        streamTranscriber = transcriber
        streamMode = mode

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
        let mode = streamMode
        streamMode = nil

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

        // AudioStreamTranscriber.State doesn't surface Whisper's language hint.
        // If we locked the decoder to a specific language (English-only mode)
        // we already know the answer and can skip NLLanguageRecognizer entirely.
        // Otherwise (multilingual) run a quick local detection on the output.
        let detectedLanguage: String?
        if let forced = mode?.whisperLanguage {
            detectedLanguage = forced
        } else if text.isEmpty {
            detectedLanguage = nil
        } else {
            detectedLanguage = Self.detectLanguage(in: text)
        }

        logger.notice("Streaming finished: \(text.count) chars (\(confirmedSegments.count) confirmed + \(unconfirmedSegments.count) unconfirmed segments), language: \(detectedLanguage ?? "unknown", privacy: .public)")
        return TranscriptionResult(text: text, detectedLanguage: detectedLanguage)
    }

    private static func detectLanguage(in text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Cancels a streaming session without harvesting results.
    func cancelStreaming() async {
        guard let transcriber = streamTranscriber else { return }
        await transcriber.stopStreamTranscription()
        streamLoopTask?.cancel()
        streamLoopTask = nil
        streamTranscriber = nil
        streamMode = nil
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

/// Wraps WhisperKit's `AudioProcessor` so every call that would otherwise
/// default to the system input is redirected to a specific CoreAudio device.
/// `AudioStreamTranscriber.startStreamTranscription()` invokes
/// `startRecordingLive(callback:)` with no device ID — this shim substitutes
/// the pinned ID so the user's Microphone-tab selection is honored in
/// streaming mode.
final class DevicePinnedAudioProcessor: NSObject, AudioProcessing, @unchecked Sendable {
    private let wrapped: AudioProcessor
    private let pinnedDeviceID: AudioDeviceID

    init(deviceID: AudioDeviceID) {
        self.wrapped = AudioProcessor()
        self.pinnedDeviceID = deviceID
        super.init()
    }

    // MARK: - Forwarding

    var audioSamples: ContiguousArray<Float> { wrapped.audioSamples }
    var relativeEnergy: [Float] { wrapped.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { wrapped.relativeEnergyWindow }
        set { wrapped.relativeEnergyWindow = newValue }
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        wrapped.purgeAudioSamples(keepingLast: keep)
    }

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try wrapped.startRecordingLive(inputDeviceID: pinnedDeviceID, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        wrapped.startStreamingRecordingLive(inputDeviceID: pinnedDeviceID)
    }

    func pauseRecording() { wrapped.pauseRecording() }
    func stopRecording() { wrapped.stopRecording() }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try wrapped.resumeRecordingLive(inputDeviceID: pinnedDeviceID, callback: callback)
    }

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        wrapped.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    static func loadAudio(
        fromPath audioFilePath: String,
        channelMode: ChannelMode,
        startTime: Double?,
        endTime: Double?,
        maxReadFrameSize: AVAudioFrameCount?
    ) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(
            fromPath: audioFilePath,
            channelMode: channelMode,
            startTime: startTime,
            endTime: endTime,
            maxReadFrameSize: maxReadFrameSize
        )
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int,
        saveSegment: Bool
    ) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: saveSegment
        )
    }
}
