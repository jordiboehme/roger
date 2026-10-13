import AVFoundation
import Foundation

/// Encodes a dictation buffer (16 kHz mono Float32, as captured by
/// `AudioCaptureService`) to an AAC `.m4a` file.
enum LogAudioEncoder {
    static let sampleRate: Double = 16000

    enum EncodeError: Error {
        case bufferUnavailable
    }

    static func writeM4A(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw EncodeError.bufferUnavailable }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // If AVAudioFile rejects these settings at 16 kHz, drop the
        // AVEncoderBitRateKey line and let the encoder pick the bit rate.
        // The file is closed when `file` goes out of scope at the end of this function.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
