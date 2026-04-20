import AVFoundation
import CoreAudio
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AudioCapture")

final class AudioCaptureService: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var capturedSamples: [Float] = []
    private let lock = NSLock()

    /// Target sample rate for WhisperKit (16kHz mono)
    static let targetSampleRate: Double = 16000

    /// Duration of the silent warm-up capture that wakes the CoreAudio HAL.
    static let warmUpDuration: TimeInterval = 0.5

    /// UID of the input device to use, or nil for system default.
    var preferredInputUID: String?

    /// Runs a short silent capture to wake the audio HAL so the next real
    /// capture gets samples immediately. Never throws; logs and returns.
    func warmUp() async {
        do {
            try startCapture()
            try? await Task.sleep(nanoseconds: UInt64(Self.warmUpDuration * 1_000_000_000))
            let samples = stopCapture()
            let count = samples?.count ?? 0
            if count == 0 {
                logger.info("Mic warm-up produced no samples — HAL may be fully asleep")
            } else {
                logger.info("Mic warm-up done (\(count) samples)")
            }
        } catch {
            logger.info("Mic warm-up skipped: \(error.localizedDescription)")
        }
    }

    func startCapture() throws {
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
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

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
        let boundDeviceID = currentDeviceID(for: inputNode)
        let boundDeviceDescription: String
        if let id = boundDeviceID {
            boundDeviceDescription = "device \(id)"
        } else {
            boundDeviceDescription = "unknown device"
        }
        logger.info("Audio capture started on \(boundDeviceDescription, privacy: .public) at \(inputFormat.sampleRate)Hz (\(inputFormat.channelCount)ch), converting to \(Self.targetSampleRate)Hz")
    }

    func stopCapture() -> [Float]? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        lock.lock()
        let samples = capturedSamples
        capturedSamples = []
        lock.unlock()

        guard !samples.isEmpty else {
            logger.warning("No samples captured")
            return nil
        }

        let peakAmplitude = samples.map { abs($0) }.max() ?? 0
        logger.notice("Captured \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / Self.targetSampleRate))s), peak amplitude: \(String(format: "%.4f", peakAmplitude))")
        return samples
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
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No audio input device found"
        }
    }
}
