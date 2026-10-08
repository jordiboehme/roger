import AVFoundation
import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AudioFileLoader")

/// Reads an audio file into 16 kHz mono Float32 samples for Parakeet, reading
/// past packets the system decoder cannot handle.
///
/// FluidAudio's `AudioConverter.resampleAudioFile` treats any read error after
/// the first chunk as end of file. Teams recordings contain runs of tiny AAC
/// packets that make Apple's decoder throw paramErr (-50) mid-file, so a 78 min
/// meeting came back as its first 20 minutes. Here a failed read is retried in
/// small steps; frames that still fail are skipped and filled with silence so
/// token timings stay on the source clock.
enum AudioFileLoader {
    enum LoadError: LocalizedError {
        case failedToCreateBuffer

        var errorDescription: String? {
            "Couldn't allocate an audio buffer."
        }
    }

    /// Consecutive undecodable audio after which the rest of the file is
    /// treated as unreadable rather than skipped.
    private static let maxConsecutiveGapSeconds = 5.0

    static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let largeChunk = AVAudioFramePosition(max(4096, Int(rate)))
        // After a failure, read in 100 ms steps so only the bad packet's
        // neighbourhood is lost, not the whole one-second chunk around it.
        let smallChunk = AVAudioFramePosition(max(1024, Int(rate / 10)))

        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        var chunk = largeChunk
        var gapStart: AVAudioFramePosition?
        var skippedFrames: AVAudioFramePosition = 0
        var gapCount = 0
        var cleanSmallReads = 0

        while file.framePosition < file.length {
            let position = file.framePosition
            let frames = min(chunk, file.length - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw LoadError.failedToCreateBuffer
            }
            do {
                try file.read(into: buffer)
            } catch {
                // A throw on the very first read is a genuinely unreadable file.
                if samples.isEmpty { throw error }
                if chunk == largeChunk {
                    // Retry the same span in small steps to find the bad packet.
                    chunk = smallChunk
                    file.framePosition = position
                    continue
                }
                cleanSmallReads = 0
                if gapStart == nil {
                    gapStart = position
                    gapCount += 1
                }
                let next = min(position + smallChunk, file.length)
                if Double(next - gapStart!) / rate > maxConsecutiveGapSeconds {
                    logger.warning("Stopped reading \(url.lastPathComponent, privacy: .public) at \(Double(gapStart!) / rate, format: .fixed(precision: 1))s: audio undecodable for over \(Int(maxConsecutiveGapSeconds))s")
                    break
                }
                samples.append(contentsOf: repeatElement(0, count: Int(next - position)))
                skippedFrames += next - position
                file.framePosition = next
                continue
            }
            if buffer.frameLength == 0 { break }
            gapStart = nil
            if chunk == smallChunk {
                // A second of clean small reads means the trouble spot is behind us.
                cleanSmallReads += 1
                if cleanSmallReads >= 10 {
                    chunk = largeChunk
                    cleanSmallReads = 0
                }
            }
            appendMono(buffer, to: &samples)
        }

        if gapCount > 0 {
            logger.notice("Skipped \(gapCount) undecodable stretch(es), \(Double(skippedFrames) / rate, format: .fixed(precision: 1))s in total, in \(url.lastPathComponent, privacy: .public)")
        }
        return try AudioConverter().resample(samples, from: rate)
    }

    private static func appendMono(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frameCount))
            return
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            samples.append(sum * scale)
        }
    }
}
