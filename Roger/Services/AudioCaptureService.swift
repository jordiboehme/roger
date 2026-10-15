import AVFoundation
import CoreAudio
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AudioCapture")

final class AudioCaptureService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    /// The engine a running warm-up or probe started, nil otherwise. A recording
    /// that starts meanwhile takes over; the warm-up or probe then leaves its engine alone.
    private var backgroundEngine: AVAudioEngine?
    private var capturedSamples: [Float] = []
    private var tapBufferCount = 0
    private var captureStartedAt: Date?
    private let lock = NSLock()
    /// Guards `audioEngine`, `backgroundEngine` and `captureStartedAt`. Warm-up and
    /// probe run off the main actor while recordings run on it. Recursive because
    /// the warm-up and probe call stopCapture() while holding it.
    private let stateLock = NSRecursiveLock()

    /// Target sample rate for WhisperKit (16kHz mono)
    static let targetSampleRate: Double = 16000

    /// Duration of the silent warm-up capture that wakes the CoreAudio HAL.
    static let warmUpDuration: TimeInterval = 0.5

    /// Minimum engine runtime before "zero buffers" counts as starvation
    /// rather than an unlucky short window.
    static let minStarvationWindow: TimeInterval = 0.4

    /// User-facing guidance for the CoreAudio wedge seen on macOS 26.5.x:
    /// permission granted and the engine runs, but the audio server never
    /// delivers a buffer to this client. Only a fresh process (or a fresh
    /// coreaudiod) recovers.
    static let halStarvedAdvice = "macOS audio server is not delivering microphone data to Roger. Relaunch Roger - if it recurs, run 'sudo killall coreaudiod' in Terminal or reboot"

    /// Post-capture health verdict. Tells "user was silent" (buffers flowed,
    /// amplitudes near zero) apart from the coreaudiod wedge (engine ran,
    /// the input tap never fired once).
    enum CaptureHealth: Equatable, Sendable {
        case ok
        /// Engine ran at least `minStarvationWindow` yet the tap never
        /// fired — the audio server is starving this client.
        case halStarved
        /// Capture too short (or never started) to judge.
        case indeterminate
    }

    struct CaptureResult: Sendable {
        let samples: [Float]?
        let health: CaptureHealth
        /// When the engine started, nil when it never ran. Lines the mic
        /// track up with the system track of a log.
        var startedAt: Date? = nil
    }

    /// UID of the input device to use, or nil for system default.
    var preferredInputUID: String?

    /// Fires on every captured buffer with its RMS level (~0…1), so the
    /// floating indicator's waveform stays live during batch dictation. Invoked
    /// off the main actor — hop before touching main-actor state.
    var onLevelUpdate: (@Sendable (Float) -> Void)?

    /// Runs a short silent capture to wake the audio HAL so the next real
    /// capture gets samples immediately. Never throws; logs and returns.
    func warmUp() async {
        guard !isCapturing else { return }
        do {
            let mine = try startBackgroundCapture()
            try? await Task.sleep(nanoseconds: UInt64(Self.warmUpDuration * 1_000_000_000))
            // A recording took over while we slept: it owns the engine now.
            guard let result = finishBackgroundCapture(mine) else {
                logger.info("Mic warm-up superseded by a recording")
                return
            }
            let count = result.samples?.count ?? 0
            if result.health == .halStarved {
                logger.error("Mic warm-up starved — the audio server delivered no buffers to this process (wedge suspect)")
            } else if count == 0 {
                logger.info("Mic warm-up produced no samples — HAL may be fully asleep")
            } else {
                logger.info("Mic warm-up done (\(count) samples)")
            }
        } catch {
            logger.info("Mic warm-up skipped: \(error.localizedDescription)")
        }
    }

    private var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioEngine != nil
    }

    /// Starts a warm-up or probe capture and returns its engine. Throws `busy`
    /// while a capture runs.
    private func startBackgroundCapture() throws -> AVAudioEngine? {
        stateLock.lock()
        defer { stateLock.unlock() }
        try startCapture(forWarmUp: true)
        return backgroundEngine
    }

    /// Stops the warm-up or probe capture `mine`, or returns nil when a recording
    /// took it over meanwhile (then the engine is left alone).
    private func finishBackgroundCapture(_ mine: AVAudioEngine?) -> CaptureResult? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let mine, backgroundEngine === mine, audioEngine === mine else { return nil }
        backgroundEngine = nil
        return stopCapture()
    }

    func startCapture() throws {
        try startCapture(forWarmUp: false)
    }

    private func startCapture(forWarmUp: Bool) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        // A warm-up or probe never takes over a running capture.
        if forWarmUp, audioEngine != nil { throw AudioCaptureError.busy }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.permissionDenied
        }

        // A recording always wins: drop a warm-up that is still running.
        if !forWarmUp, let stale = backgroundEngine {
            stale.inputNode.removeTap(onBus: 0)
            stale.stop()
            if audioEngine === stale { audioEngine = nil }
            backgroundEngine = nil
            logger.info("Stopped a running mic warm-up for a recording")
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let uid = preferredInputUID {
            if let deviceID = AudioDeviceLookup.deviceID(forUID: uid) {
                applyDeviceID(deviceID, to: inputNode)
            } else {
                logger.warning("Preferred input UID \(uid, privacy: .public) not present among available devices — using system default")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        lock.lock()
        capturedSamples = []
        tapBufferCount = 0
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Counted before conversion: health tracks whether the HAL
            // delivered anything at all, independent of conversion issues.
            self.lock.lock()
            self.tapBufferCount += 1
            self.lock.unlock()

            if let converter {
                let ratio = Self.targetSampleRate / inputFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrameCount
                ) else { return }

                var error: NSError?
                var inputConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if let error {
                    logger.error("Audio conversion error: \(error)")
                    return
                }

                self.appendSamples(from: convertedBuffer)
            } else {
                self.appendSamples(from: buffer)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        if forWarmUp { backgroundEngine = engine }
        captureStartedAt = Date()
        let boundDeviceID = currentDeviceID(for: inputNode)
        let boundDeviceDescription: String
        if let id = boundDeviceID {
            boundDeviceDescription = "device \(id)"
        } else {
            boundDeviceDescription = "unknown device"
        }
        logger.info("Audio capture started on \(boundDeviceDescription, privacy: .public) at \(inputFormat.sampleRate)Hz (\(inputFormat.channelCount)ch), converting to \(Self.targetSampleRate)Hz")
    }

    @discardableResult
    func stopCapture() -> CaptureResult {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wasRunning = audioEngine != nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        let startedAt = captureStartedAt
        let observed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        captureStartedAt = nil

        lock.lock()
        let samples = capturedSamples
        let bufferCount = tapBufferCount
        capturedSamples = []
        tapBufferCount = 0
        lock.unlock()

        let health: CaptureHealth
        if !wasRunning || observed < Self.minStarvationWindow {
            health = .indeterminate
        } else if bufferCount == 0 {
            health = .halStarved
        } else {
            health = .ok
        }

        if health == .halStarved {
            logger.error("HAL starvation: engine ran \(String(format: "%.2f", observed), privacy: .public)s without a single input buffer — audio server is wedged (relaunch Roger or restart coreaudiod)")
        }

        guard !samples.isEmpty else {
            logger.warning("No samples captured")
            return CaptureResult(samples: nil, health: health, startedAt: startedAt)
        }

        let peakAmplitude = samples.map { abs($0) }.max() ?? 0
        logger.notice("Captured \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / Self.targetSampleRate))s), peak amplitude: \(String(format: "%.4f", peakAmplitude))")
        return CaptureResult(samples: samples, health: health, startedAt: startedAt)
    }

    /// Short capture probe for the settings test buttons. Retries once when
    /// the first attempt yields nothing — a cold HAL legitimately needs one
    /// capture as a wake-up call, and the retry keeps a sleeping HAL from
    /// being misreported as the coreaudiod wedge.
    func probe(duration: TimeInterval = 0.5) async throws -> CaptureResult {
        var last = CaptureResult(samples: nil, health: .indeterminate)
        for attempt in 1...2 {
            // A recording always wins over a probe.
            let mine = try startBackgroundCapture()
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let result = finishBackgroundCapture(mine) else {
                logger.info("Mic probe superseded by a recording")
                return last
            }
            last = result
            if let samples = last.samples, !samples.isEmpty {
                return last
            }
            logger.info("Mic probe attempt \(attempt) came back empty (health: \(String(describing: last.health), privacy: .public))")
        }
        return last
    }

    private func applyDeviceID(_ deviceID: AudioDeviceID, to inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else {
            logger.warning("Input node has no underlying AudioUnit; cannot set device")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            let fallback = currentDeviceID(for: inputNode).map(String.init) ?? "unknown"
            logger.error("Failed to set input device \(deviceID) (OSStatus \(status)) — engine will use current device \(fallback, privacy: .public)")
        } else {
            logger.info("Input device set to \(deviceID)")
        }
    }

    /// Reads back the CoreAudio device currently bound to the input node.
    /// Returns nil when the node has no AudioUnit or the property query fails —
    /// this is best-effort diagnostic telemetry, not a correctness check.
    private func currentDeviceID(for inputNode: AVAudioInputNode) -> AudioDeviceID? {
        guard let audioUnit = inputNode.audioUnit else { return nil }
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

    private func appendSamples(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
        lock.lock()
        capturedSamples.append(contentsOf: samples)
        lock.unlock()

        if let onLevelUpdate, !samples.isEmpty {
            var sumSquares: Float = 0
            for s in samples { sumSquares += s * s }
            let rms = (sumSquares / Float(samples.count)).squareRoot()
            onLevelUpdate(rms)
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case permissionDenied
    case busy

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device found"
        case .permissionDenied:
            return "Microphone access denied. Grant permission in System Settings > Privacy & Security."
        case .busy:
            return "The microphone is in use by a recording."
        }
    }
}
