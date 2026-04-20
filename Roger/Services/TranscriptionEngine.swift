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
    // `any AudioProcessing` isn't Sendable, but we only touch this reference
    // before `startStreamTranscription` returns and after `streamLoopTask`
    // has awaited to completion — the actor's loop never runs concurrently
    // with our reads of `audioSamples` in `finishStreaming`.
    nonisolated(unsafe) private var streamAudioProcessor: (any AudioProcessing)?
    private let latestStreamSnapshot = OSAllocatedUnfairLock<StreamSnapshot?>(initialState: nil)
    private let streamPeakEnergy = OSAllocatedUnfairLock<Float>(initialState: 0)

    /// Peak audio energy observed during the most recently completed streaming
    /// session. Zero after a session where CoreAudio delivered no samples —
    /// the key signal that something below Roger (TCC, MDM, HAL routing)
    /// silently dropped input.
    private(set) var lastStreamPeakEnergy: Float = 0

    /// Fires on every state-change callback from WhisperKit with the most
    /// recent per-chunk energy. Invoked off the main actor — hop before
    /// touching main-actor state.
    var onLevelUpdate: (@Sendable (Float) -> Void)?

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
        streamPeakEnergy.withLock { $0 = 0 }
        lastStreamPeakEnergy = 0

        let options = DecodingOptions(
            language: mode.whisperLanguage,
            detectLanguage: mode.whisperLanguage == nil,
            skipSpecialTokens: true,
            suppressBlank: true
        )

        // Pin the user's selected input device into the AudioProcessor so
        // AudioStreamTranscriber's own startRecordingLive() call routes to it.
        // Assigning to `streamAudioProcessor` before handing the reference to
        // the actor initializer avoids Swift 6's region-based "sending"
        // warning: the local variable goes out of scope immediately after the
        // assignment, leaving only one path to the object.
        if let deviceID = inputDeviceID {
            streamAudioProcessor = DevicePinnedAudioProcessor(deviceID: deviceID)
            logger.info("Streaming with pinned input device \(deviceID)")
        } else {
            streamAudioProcessor = whisperKit.audioProcessor
            logger.info("Streaming with system default input device")
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
            audioProcessor: streamAudioProcessor!,
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
    /// confirmed and unconfirmed segments, plus a final batch pass over any
    /// tail audio the streaming loop skipped.
    func finishStreaming() async throws -> TranscriptionResult {
        guard let transcriber = streamTranscriber else {
            throw TranscriptionError.engineNotReady
        }

        // Stop first so `isRecording` flips; then await the loop task so any
        // in-flight transcription completes and its final state callback
        // stores the last snapshot. Cancelling here would truncate that.
        await transcriber.stopStreamTranscription()
        await streamLoopTask?.value
        streamLoopTask = nil
        streamTranscriber = nil
        let mode = streamMode
        streamMode = nil
        let audioProcessor = streamAudioProcessor
        streamAudioProcessor = nil

        let snapshot = latestStreamSnapshot.withLock { value -> StreamSnapshot? in
            let snap = value
            value = nil
            return snap
        }

        let confirmedSegments = snapshot?.confirmedSegments ?? []
        let unconfirmedSegments = snapshot?.unconfirmedSegments ?? []
        let segments = confirmedSegments + unconfirmedSegments
        let streamedText = segments
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // WhisperKit's `realtimeLoop` only transcribes when >1s of new audio
        // has accumulated since the last pass — anything spoken in the final
        // <1s before stop never gets transcribed. Pull the raw buffer and run
        // a batch pass over just the tail.
        let tailText = await transcribeTail(
            audioProcessor: audioProcessor,
            confirmedSegments: confirmedSegments,
            unconfirmedSegments: unconfirmedSegments,
            mode: mode
        )

        let text: String
        if tailText.isEmpty {
            text = streamedText
        } else if streamedText.isEmpty {
            text = tailText
        } else {
            text = streamedText + " " + tailText
        }

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

        let peakEnergy = streamPeakEnergy.withLock { $0 }
        lastStreamPeakEnergy = peakEnergy
        logger.notice("Streaming finished: \(text.count) chars (\(confirmedSegments.count) confirmed + \(unconfirmedSegments.count) unconfirmed + \(tailText.isEmpty ? "no" : "\(tailText.count)-char") tail), peak energy \(String(format: "%.3f", peakEnergy), privacy: .public), language: \(detectedLanguage ?? "unknown", privacy: .public)")
        return TranscriptionResult(text: text, detectedLanguage: detectedLanguage)
    }

    private func transcribeTail(
        audioProcessor: (any AudioProcessing)?,
        confirmedSegments: [TranscriptionSegment],
        unconfirmedSegments: [TranscriptionSegment],
        mode: TranscriptionMode?
    ) async -> String {
        guard let audioProcessor, let whisperKit, let mode else { return "" }

        let lastSegmentEnd = max(
            confirmedSegments.last?.end ?? 0,
            unconfirmedSegments.last?.end ?? 0
        )
        let samples = audioProcessor.audioSamples
        let sampleRate = Int(AudioCaptureService.targetSampleRate)
        let tailStartIndex = Int(Double(lastSegmentEnd) * Double(sampleRate))
        let tailSampleCount = samples.count - tailStartIndex
        let minTailSamples = sampleRate / 10  // 100 ms — skip silence/click tails
        guard tailStartIndex >= 0, tailSampleCount >= minTailSamples else { return "" }

        let tail = Array(samples[tailStartIndex..<samples.count])
        let options = DecodingOptions(
            language: mode.whisperLanguage,
            detectLanguage: mode.whisperLanguage == nil,
            skipSpecialTokens: true,
            suppressBlank: true
        )

        do {
            let results = try await whisperKit.transcribe(audioArray: tail, decodeOptions: options)
            let text = results
                .compactMap(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("Tail transcription: \(String(format: "%.2f", Double(tailSampleCount) / Double(sampleRate)))s, \(text.count) chars")
            return text
        } catch {
            logger.error("Tail transcription failed: \(error.localizedDescription) — keeping streamed text only")
            return ""
        }
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
        streamAudioProcessor = nil
        latestStreamSnapshot.withLock { $0 = nil }
    }

    private func storeStreamState(_ state: AudioStreamTranscriber.State) {
        let snapshot = StreamSnapshot(
            confirmedSegments: state.confirmedSegments,
            unconfirmedSegments: state.unconfirmedSegments
        )
        latestStreamSnapshot.withLock { $0 = snapshot }
        if let peak = state.bufferEnergy.max() {
            streamPeakEnergy.withLock { current in
                if peak > current { current = peak }
            }
        }
        if let last = state.bufferEnergy.last {
            onLevelUpdate?(last)
        }
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
