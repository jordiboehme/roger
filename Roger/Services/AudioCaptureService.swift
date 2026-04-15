import AVFoundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AudioCapture")

final class AudioCaptureService {
    private var audioEngine: AVAudioEngine?
    private var capturedSamples: [Float] = []
    private let lock = NSLock()

    /// Target sample rate for WhisperKit (16kHz mono)
    static let targetSampleRate: Double = 16000

    func startCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
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
        logger.info("Audio capture started at \(inputFormat.sampleRate)Hz, converting to \(Self.targetSampleRate)Hz")
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

        logger.info("Captured \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / Self.targetSampleRate))s)")
        return samples
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
