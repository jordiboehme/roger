import AVFoundation
import Foundation
import os

/// Writes a stream of `AVAudioPCMBuffer`s to a chain of CAF chunks on disk,
/// rolling to a new file every `segmentDuration`. CAF (Core Audio Format) is
/// chosen over M4A for the active recording phase because CAF's append-only
/// model survives partial writes — if Roger crashes mid-recording, every
/// closed chunk is durable. Final encode to M4A happens at the end of the
/// session via `AudioSegmentConcatenator`.
final class SegmentedAudioFileWriter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "SegmentedAudioFileWriter")

    /// Seconds before rolling to the next chunk. 30 min default keeps memory
    /// + handle leaks bounded over a multi-hour meeting.
    let segmentDuration: TimeInterval

    /// Smallest free disk space (bytes) below which we refuse to roll over
    /// and stop the writer. 500 MB.
    private static let minFreeBytes: Int64 = 500 * 1024 * 1024

    let folder: URL
    let baseName: String
    let format: AVAudioFormat

    private let queue = DispatchQueue(label: "com.jordiboehme.roger.segwriter", qos: .userInitiated)
    private var file: AVAudioFile?
    private var currentSegmentIndex = 0
    private var currentSegmentStart: Date?
    private(set) var segments: [URL] = []
    private(set) var lastError: Error?
    private(set) var totalFramesWritten: AVAudioFramePosition = 0
    private var stopped = false

    init(folder: URL, baseName: String, format: AVAudioFormat, segmentDuration: TimeInterval) {
        self.folder = folder
        self.baseName = baseName
        self.format = format
        self.segmentDuration = max(60, segmentDuration)
    }

    /// Opens the first segment. Throws if folder isn't writable.
    func start() throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try openNextSegment()
        }
    }

    /// Appends a buffer. Safe to call from any queue. Drops the buffer (logs)
    /// if a previous error stopped the writer.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.lastError == nil else { return }
            self.writeOrRotate(buffer)
        }
    }

    /// Closes the active chunk and opens the next, so everything appended so
    /// far sits in fully flushed closed CAF files that are safe to read while
    /// recording continues (an open `AVAudioFile` has no flush API — its tail
    /// may still be buffered). Returns the closed chunk URLs. When the writer
    /// is already stopped or errored, returns the existing chunk list
    /// unchanged. Serialized on the writer queue, so it interleaves safely
    /// with `append(_:)` and the timed rolls.
    func rollSegment() async -> [URL] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                guard !self.stopped, self.lastError == nil, self.file != nil else {
                    continuation.resume(returning: self.segments)
                    return
                }
                self.rotate()
                // rotate() appends the freshly opened chunk unless it tripped
                // the disk-space gate and stopped the writer.
                let closed = self.stopped ? self.segments : Array(self.segments.dropLast())
                continuation.resume(returning: closed)
            }
        }
    }

    /// Closes the active segment. Returns the full chunk list. Safe to call
    /// once — subsequent calls are no-ops.
    func close() async -> [URL] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: []); return }
                self.stopped = true
                self.file = nil
                continuation.resume(returning: self.segments)
            }
        }
    }

    private func writeOrRotate(_ buffer: AVAudioPCMBuffer) {
        if let start = currentSegmentStart, Date().timeIntervalSince(start) >= segmentDuration {
            rotate()
        }
        guard let file else {
            // Already stopped or rotation failed — drop.
            return
        }
        do {
            try file.write(from: buffer)
            totalFramesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            Self.logger.error("Segment write failed: \(error.localizedDescription, privacy: .public)")
            lastError = error
            stopped = true
            self.file = nil
        }
    }

    private func rotate() {
        // Close existing handle.
        file = nil
        // Free-space gate.
        if !hasEnoughFreeSpace() {
            Self.logger.error("Disk space below \(Self.minFreeBytes / 1024 / 1024) MB — stopping writer")
            lastError = SegmentedAudioFileWriterError.diskSpaceExhausted
            stopped = true
            return
        }
        do {
            try openNextSegment()
        } catch {
            Self.logger.error("Failed to roll segment: \(error.localizedDescription, privacy: .public)")
            lastError = error
            stopped = true
        }
    }

    private func openNextSegment() throws {
        currentSegmentIndex += 1
        let name = String(format: "%@-%03d.caf", baseName, currentSegmentIndex)
        let url = folder.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
        file = audioFile
        segments.append(url)
        currentSegmentStart = Date()
        Self.logger.info("Opened segment \(name, privacy: .public)")
    }

    private func hasEnoughFreeSpace() -> Bool {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let bytes = values?.volumeAvailableCapacity else { return true }
        return Int64(bytes) >= Self.minFreeBytes
    }
}

enum SegmentedAudioFileWriterError: LocalizedError {
    case diskSpaceExhausted

    var errorDescription: String? {
        switch self {
        case .diskSpaceExhausted:
            return "Recording stopped — less than 500 MB free on the recordings volume."
        }
    }
}
