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
    private var streamLanguageOverride: String?
    // `any AudioProcessing` isn't Sendable, but we only touch this reference
    // before `startStreamTranscription` returns and after `streamLoopTask`
    // has awaited to completion — the actor's loop never runs concurrently
    // with our reads of `audioSamples` in `finishStreaming`.
    nonisolated(unsafe) private var streamAudioProcessor: (any AudioProcessing)?
    private let latestStreamSnapshot = OSAllocatedUnfairLock<StreamSnapshot?>(initialState: nil)
    private let streamPeakEnergy = OSAllocatedUnfairLock<Float>(initialState: 0)
    private let streamFailure = OSAllocatedUnfairLock<StreamFailure?>(initialState: nil)
    /// Observer that catches WhisperKit's AVAudioEngine auto-stopping on a
    /// hardware reconfiguration (notably Bluetooth headsets switching into
    /// HFP mode a few ms after `engine.start()`) and restarts the engine.
    /// Without this the engine stops itself within ~20 ms of starting, the
    /// session never delivers samples, and dictation ends in silence.
    private var configChangeObserver: NSObjectProtocol?
    private let configChangeRetries = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let maxConfigChangeRetries = 3

    struct StreamFailure: Sendable {
        let reason: String
        let deviceID: AudioDeviceID
    }

    /// Reads and clears the most recent stream-open failure captured by the
    /// 300 ms post-start verification task or by a throwing
    /// `startStreamTranscription()`. The caller (AppCoordinator) uses this to
    /// surface a clear error instead of the misleading "No speech detected".
    func consumeStreamFailure() -> StreamFailure? {
        streamFailure.withLock { value in
            let snap = value
            value = nil
            return snap
        }
    }

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
        await persistCurrentEtag()
        logger.info("WhisperKit ready with model: \(modelName)")
    }

    func uninstall() async {
        let folder = whisperKit?.modelFolder
        whisperKit = nil
        currentModelName = nil
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func checkForUpdate() async throws -> Bool {
        guard let modelName = currentModelName else { return false }
        guard let url = URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/\(modelName)/config.json") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return false }
        let remoteEtag = http.value(forHTTPHeaderField: "x-linked-etag") ?? http.value(forHTTPHeaderField: "etag")
        let storedEtag = UserDefaults.standard.string(forKey: "whisperKitEtag_\(modelName)")
        guard let remoteEtag else { return false }
        return remoteEtag != storedEtag
    }

    private func persistCurrentEtag() async {
        guard let modelName = currentModelName else { return }
        guard let url = URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/\(modelName)/config.json") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let etag = http.value(forHTTPHeaderField: "x-linked-etag") ?? http.value(forHTTPHeaderField: "etag")
        else { return }
        UserDefaults.standard.set(etag, forKey: "whisperKitEtag_\(modelName)")
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
    func startStreaming(mode: TranscriptionMode, languageOverride: String?, inputDeviceID: AudioDeviceID?) async throws {
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
        streamFailure.withLock { $0 = nil }
        configChangeRetries.withLock { $0 = 0 }
        lastStreamPeakEnergy = 0

        // Register the config-change observer BEFORE the detached task fires
        // `engine.start()` — on Bluetooth-equipped Macs the hardware-reroute
        // notification can arrive within ~20 ms of start, faster than any
        // post-hoc observer could beat.
        if let previous = configChangeObserver {
            NotificationCenter.default.removeObserver(previous)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleAudioEngineConfigurationChange(note)
        }

        let resolvedLanguage = languageOverride ?? mode.whisperLanguage
        let options = DecodingOptions(
            language: resolvedLanguage,
            detectLanguage: resolvedLanguage == nil,
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
        streamLanguageOverride = languageOverride

        let pinnedDeviceID = (streamAudioProcessor as? DevicePinnedAudioProcessor)?.pinnedDevice ?? 0
        let failureLock = streamFailure
        streamLoopTask = Task.detached {
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                logger.error("Streaming transcription loop failed: \(error.localizedDescription)")
                failureLock.withLock { current in
                    if current == nil {
                        current = StreamFailure(
                            reason: "startStreamTranscription threw: \(error.localizedDescription)",
                            deviceID: pinnedDeviceID
                        )
                    }
                }
            }
        }

        // Poll up to 1.2 s for the HAL to actually come up. WhisperKit's
        // setupEngine takes ~340 ms on slower Macs, so a single 300 ms read
        // reports a false "not running" on healthy sessions. The loop exits
        // the moment the engine flips to running; only a full-budget miss
        // records a `StreamFailure` for the coordinator to surface.
        let transcriberIdentity = ObjectIdentifier(transcriber)
        Task { [weak self] in
            let started = Date()
            let deadline = started.addingTimeInterval(1.2)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                guard let current = self.streamTranscriber, ObjectIdentifier(current) == transcriberIdentity else {
                    return
                }
                if self.currentStreamEngine()?.isRunning == true {
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    logger.notice("Stream verify ok: engine running after \(ms, privacy: .public) ms")
                    return
                }
            }
            guard let self,
                  let current = self.streamTranscriber,
                  ObjectIdentifier(current) == transcriberIdentity else {
                return
            }
            let engine = self.currentStreamEngine()
            let engineRunning = engine?.isRunning ?? false
            let bound = Self.boundDevice(for: engine?.inputNode)
            let effectiveDeviceID: AudioDeviceID = pinnedDeviceID != 0 ? pinnedDeviceID : (bound ?? 0)
            let deviceRunning = Self.deviceIsRunning(effectiveDeviceID)
            let boundStr = bound.map(String.init) ?? "unknown"
            logger.error("Stream verify FAILED after 1.2s: engine.isRunning=\(engineRunning, privacy: .public), device[\(effectiveDeviceID, privacy: .public)].isRunning=\(deviceRunning, privacy: .public), boundDevice=\(boundStr, privacy: .public)")
            if !engineRunning && !deviceRunning {
                failureLock.withLock { current in
                    if current == nil {
                        current = StreamFailure(
                            reason: "engine and device both not running 1.2 s after start (bound=\(boundStr))",
                            deviceID: effectiveDeviceID
                        )
                    }
                }
            }
        }
    }

    /// Resolves WhisperKit's underlying AVAudioEngine whether streaming runs
    /// through our `DevicePinnedAudioProcessor` wrapper (Microphone tab has a
    /// specific device selected) or through WhisperKit's default
    /// `AudioProcessor` (Automatic input).
    private func currentStreamEngine() -> AVAudioEngine? {
        if let pinned = streamAudioProcessor as? DevicePinnedAudioProcessor {
            return pinned.audioEngine
        }
        if let plain = streamAudioProcessor as? AudioProcessor {
            return plain.audioEngine
        }
        return nil
    }

    private func handleAudioEngineConfigurationChange(_ note: Notification) {
        guard let posted = note.object as? AVAudioEngine else { return }
        guard streamAudioProcessor != nil else { return }
        // WhisperKit stores the engine on `AudioProcessor.audioEngine` only
        // after `setupEngine` returns, but the most important config-change
        // notification fires *inside* `setupEngine` during `assignAudioInput`.
        // If our tracked engine is nil we're in that window — trust the
        // posted object. If it's non-nil, require the references to match so
        // we don't act on unrelated engines.
        if let tracked = currentStreamEngine(), posted !== tracked { return }
        let attempt = configChangeRetries.withLock { current -> Int in
            current += 1
            return current
        }
        guard attempt <= Self.maxConfigChangeRetries else {
            logger.warning("AVAudioEngine config change fired \(attempt) times — giving up to avoid an infinite restart loop")
            return
        }
        logger.warning("AVAudioEngine config changed (attempt \(attempt)/\(Self.maxConfigChangeRetries)); posted.isRunning=\(posted.isRunning, privacy: .public) — restarting")
        do {
            if !posted.isRunning {
                try posted.start()
                logger.info("Engine restarted after config change")
            }
        } catch {
            logger.error("Engine restart after config change failed: \(error.localizedDescription)")
        }
    }

    private static func deviceIsRunning(_ id: AudioDeviceID) -> Bool {
        guard id != 0 else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func boundDevice(for inputNode: AVAudioInputNode?) -> AudioDeviceID? {
        guard let audioUnit = inputNode?.audioUnit else { return nil }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            &size
        )
        return status == noErr ? id : nil
    }

    /// Stops a streaming session and returns the combined text from all
    /// confirmed and unconfirmed segments, plus a final batch pass over any
    /// tail audio the streaming loop skipped.
    func finishStreaming() async throws -> TranscriptionResult {
        guard let transcriber = streamTranscriber else {
            throw TranscriptionError.engineNotReady
        }

        // Give the AVAudioEngine tap 400 ms to deliver any in-flight CoreAudio
        // buffers before we stop the engine. AVAudioEngine.stop() doesn't drain
        // the tap queue, so without this the user's last ~100–300 ms of speech
        // (whatever was captured but not yet posted to the tap at release time)
        // never reaches audioSamples and the tail-transcription pass has
        // nothing to work with — matching the "last word missing" reports.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Stop first so `isRecording` flips; then await the loop task so any
        // in-flight transcription completes and its final state callback
        // stores the last snapshot. Cancelling here would truncate that.
        await transcriber.stopStreamTranscription()
        await streamLoopTask?.value
        streamLoopTask = nil
        streamTranscriber = nil
        let mode = streamMode
        streamMode = nil
        let languageOverride = streamLanguageOverride
        streamLanguageOverride = nil
        let audioProcessor = streamAudioProcessor
        streamAudioProcessor = nil
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }

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
            mode: mode,
            languageOverride: languageOverride
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
        // If we locked the decoder to a specific language (English-only mode
        // or a per-preset override) we already know the answer and can skip
        // NLLanguageRecognizer entirely. Otherwise run local detection.
        let detectedLanguage: String?
        if let forced = languageOverride ?? mode?.whisperLanguage {
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
        mode: TranscriptionMode?,
        languageOverride: String?
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
        let resolvedLanguage = languageOverride ?? mode.whisperLanguage
        let options = DecodingOptions(
            language: resolvedLanguage,
            detectLanguage: resolvedLanguage == nil,
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
        streamLanguageOverride = nil
        streamAudioProcessor = nil
        latestStreamSnapshot.withLock { $0 = nil }
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
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

    // MARK: - File Transcription

    /// Transcribes an audio file directly (no microphone capture). Used for
    /// the menu bar drag-and-drop flow. WhisperKit loads and chunks the file
    /// internally via `transcribe(audioPath:decodeOptions:)`.
    func transcribeFile(url: URL, mode: TranscriptionMode, languageOverride: String?) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionError.engineNotReady
        }

        let resolvedLanguage = languageOverride ?? mode.whisperLanguage
        let options = DecodingOptions(
            language: resolvedLanguage,
            detectLanguage: resolvedLanguage == nil,
            skipSpecialTokens: true,
            suppressBlank: true
        )

        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let detectedLanguage: String?
        if let forced = resolvedLanguage {
            detectedLanguage = forced
        } else if text.isEmpty {
            detectedLanguage = nil
        } else {
            detectedLanguage = Self.detectLanguage(in: text)
        }

        logger.notice("File transcription: \(url.lastPathComponent, privacy: .public) → \(text.count) chars, language \(detectedLanguage ?? "unknown", privacy: .public)")
        return TranscriptionResult(text: text, detectedLanguage: detectedLanguage)
    }

    /// Loads audio into [Float] and transcribes with word timestamps enabled.
    /// Returns the raw WhisperKit segments and audio samples so the caller can
    /// run SpeakerKit diarization without loading the audio a second time.
    func transcribeFileDetailed(url: URL, mode: TranscriptionMode, languageOverride: String?) async throws -> DetailedTranscriptionResult {
        guard let whisperKit else { throw TranscriptionError.engineNotReady }

        let audioSamples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)

        let resolvedLanguage = languageOverride ?? mode.whisperLanguage
        let options = DecodingOptions(
            language: resolvedLanguage,
            detectLanguage: resolvedLanguage == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            suppressBlank: true
        )
        let rawSegments = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)

        let text = rawSegments
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let detectedLanguage: String?
        if let forced = resolvedLanguage {
            detectedLanguage = forced
        } else if text.isEmpty {
            detectedLanguage = nil
        } else {
            detectedLanguage = Self.detectLanguage(in: text)
        }

        logger.notice("File transcription (detailed): \(url.lastPathComponent, privacy: .public) → \(text.count) chars, \(rawSegments.count) segments, language \(detectedLanguage ?? "unknown", privacy: .public)")
        return DetailedTranscriptionResult(
            result: TranscriptionResult(text: text, detectedLanguage: detectedLanguage),
            rawSegments: rawSegments,
            audioSamples: audioSamples
        )
    }

    // MARK: - Batch Transcription

    func transcribe(audioBuffer: [Float], mode: TranscriptionMode, languageOverride: String?) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionError.engineNotReady
        }

        let resolvedLanguage = languageOverride ?? mode.whisperLanguage
        let options = DecodingOptions(
            language: resolvedLanguage,
            detectLanguage: resolvedLanguage == nil, // auto-detect for multilingual
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

/// Returned by `TranscriptionEngine.transcribeFileDetailed` — holds the WhisperKit
/// segments and audio samples so the caller can pass them directly to SpeakerKit
/// without re-loading the audio.
struct DetailedTranscriptionResult: Sendable {
    let result: TranscriptionEngine.TranscriptionResult
    // TranscriptionResult at file scope resolves to WhisperKit's type (no local shadowing here)
    let rawSegments: [TranscriptionResult]
    let audioSamples: [Float]
}

/// Wraps WhisperKit's `AudioProcessor` so every call that would otherwise
/// default to the system input is redirected to a specific CoreAudio device.
/// `AudioStreamTranscriber.startStreamTranscription()` invokes
/// `startRecordingLive(callback:)` with no device ID — this shim substitutes
/// the pinned ID so the user's Microphone-tab selection is honored in
/// streaming mode.
final class DevicePinnedAudioProcessor: NSObject, AudioProcessing, @unchecked Sendable {
    private let wrapped: AudioProcessor
    let pinnedDevice: AudioDeviceID

    init(deviceID: AudioDeviceID) {
        self.wrapped = AudioProcessor()
        self.pinnedDevice = deviceID
        super.init()
    }

    /// Reads the underlying AVAudioEngine that WhisperKit builds inside
    /// `startRecordingLive`. Used by `TranscriptionEngine` to verify the
    /// engine actually started after `startStreamTranscription()` returns.
    var audioEngine: AVAudioEngine? { wrapped.audioEngine }

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
        try wrapped.startRecordingLive(inputDeviceID: pinnedDevice, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        wrapped.startStreamingRecordingLive(inputDeviceID: pinnedDevice)
    }

    func pauseRecording() { wrapped.pauseRecording() }
    func stopRecording() { wrapped.stopRecording() }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        try wrapped.resumeRecordingLive(inputDeviceID: pinnedDevice, callback: callback)
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
