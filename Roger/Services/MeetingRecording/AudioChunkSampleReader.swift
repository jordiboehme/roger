import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AudioChunkSampleReader")

/// Reads closed 16 kHz mono float32 CAF chunks, in order, into one contiguous
/// sample array — the format `SegmentedAudioFileWriter` produces and the ASR
/// engine consumes, so no resampling is involved. Unreadable or empty chunks
/// are skipped with a warning. Heavy on memory for long recordings (same
/// order as the existing finalisation path, which also loads whole tracks);
/// call from a background task, never the main actor.
enum AudioChunkSampleReader {
    static func samples(from chunkURLs: [URL]) -> [Float] {
        var output: [Float] = []
        for url in chunkURLs {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                logger.warning("Skipping unreadable chunk \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let format = file.processingFormat
            guard format.channelCount >= 1, file.length > 0 else { continue }
            output.reserveCapacity(output.count + Int(file.length))

            let blockFrames: AVAudioFrameCount = 1 << 20
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { break }
                do {
                    try file.read(into: buffer, frameCount: blockFrames)
                } catch {
                    logger.warning("Read failed in \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    break
                }
                guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        }
        return output
    }
}
