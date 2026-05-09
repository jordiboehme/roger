import AVFoundation
import CoreAudio
import Foundation
import os

/// Sendable wrapper around `ProcessTap` that exposes captured system audio as
/// a stream of `AVAudioPCMBuffer` already converted to 16 kHz mono float32 —
/// the format `WhisperKit` and `SegmentedAudioFileWriter` both consume. The
/// IOProc thread does only a single buffer copy + dispatch hop; format
/// conversion and stream delivery happen on a serial writer queue.
final class SystemAudioTap: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "SystemAudioTap")

    /// Sample rate Whisper expects.
    static let targetSampleRate: Double = 16_000

    private let tap = ProcessTap()
    private let writerQueue = DispatchQueue(label: "com.jordiboehme.roger.systemtap.writer", qos: .userInteractive)

    /// Pre-allocated mono float32 target buffers — rotated to avoid heap churn
    /// in the hot path. Sized for ~250 ms at 16 kHz, plenty of slack for a
    /// 4096-frame source packet.
    private static let ringSize = 8
    private static let bufferCapacity: AVAudioFrameCount = 4_096
    private var ring: [AVAudioPCMBuffer] = []
    private var ringIndex = 0

    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private(set) var droppedBuffers = 0

    /// Starts capture and returns an async sequence of converted buffers.
    /// Call `stop()` to tear down.
    func startStreaming() throws -> AsyncStream<SendableAudioBuffer> {
        try tap.activate()
        guard let asbd = tap.streamDescription else {
            throw ProcessTapError.formatReadFailed
        }
        var fmt = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &fmt) else {
            throw ProcessTapError.formatReadFailed
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw ProcessTapError.formatReadFailed
        }
        self.inputFormat = inputFormat
        self.converter = converter

        ring = (0 ..< Self.ringSize).compactMap {
            _ in AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: Self.bufferCapacity)
        }

        let stream = AsyncStream<SendableAudioBuffer>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Self.logger.info("System audio stream consumer terminated")
            }
        }

        tap.bufferHandler = { [weak self] bufferList, _ in
            self?.ingest(bufferList: bufferList, inputFormat: inputFormat)
        }

        Self.logger.notice("SystemAudioTap streaming (\(inputFormat.sampleRate, privacy: .public) Hz × \(inputFormat.channelCount, privacy: .public)ch → \(Self.targetSampleRate, privacy: .public) Hz mono)")
        return stream
    }

    /// Stops capture; the AsyncStream finishes after the last buffer drains.
    func stop() {
        writerQueue.async { [weak self] in
            self?.tap.bufferHandler = nil
            self?.tap.invalidate()
            self?.continuation?.finish()
            self?.continuation = nil
            self?.converter = nil
            self?.ring = []
        }
    }

    /// Called on the IOProc dispatch queue (real-time priority). Wraps the
    /// raw `AudioBufferList` into an `AVAudioPCMBuffer` whose samples it
    /// COPIES into a stable backing buffer (the bufferList memory is only
    /// valid for the duration of this call), then hops to the writer queue
    /// for conversion + delivery.
    private func ingest(bufferList: UnsafePointer<AudioBufferList>, inputFormat: AVAudioFormat) {
        let abl = bufferList.pointee
        let frames = AVAudioFrameCount(Int(abl.mBuffers.mDataByteSize) / Int(inputFormat.streamDescription.pointee.mBytesPerFrame))
        guard frames > 0 else { return }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let dst = inputBuffer.audioBufferList.pointee.mBuffers.mData,
              let src = abl.mBuffers.mData else { return }
        let bytes = Int(abl.mBuffers.mDataByteSize)
        memcpy(dst, src, bytes)
        inputBuffer.frameLength = frames

        // Hop to the writer queue. Allocations above happen on the IOProc
        // thread but `AVAudioPCMBuffer.init(frameCapacity:)` is cheap
        // compared to file I/O — and the alternative (a true zero-alloc
        // path) requires manual ring-buffer plumbing and runs into Swift's
        // `Sendable` constraints around `AudioBufferList`. Acceptable for
        // 4 KB packets at <100 Hz.
        writerQueue.async { [weak self] in
            self?.convertAndDeliver(inputBuffer)
        }
    }

    private func convertAndDeliver(_ input: AVAudioPCMBuffer) {
        guard let converter, let target = nextRingSlot(), let continuation else {
            droppedBuffers += 1
            if droppedBuffers % 100 == 0 {
                Self.logger.warning("System audio dropped \(self.droppedBuffers, privacy: .public) buffers cumulative")
            }
            return
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: target, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if let error {
            Self.logger.error("System audio conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if status == .error {
            Self.logger.error("System audio conversion returned error status")
            return
        }
        if target.frameLength > 0 {
            // Continuation buffers internally; the dropOldest policy means a
            // slow consumer just shows up as a `droppedBuffers` count.
            let sent = continuation.yield(SendableAudioBuffer(buffer: target))
            switch sent {
            case .terminated:
                Self.logger.info("System audio stream consumer ended early")
            case .dropped:
                droppedBuffers += 1
            case .enqueued:
                break
            @unknown default:
                break
            }
        }
    }

    private func nextRingSlot() -> AVAudioPCMBuffer? {
        guard !ring.isEmpty else { return nil }
        let buf = ring[ringIndex]
        ringIndex = (ringIndex + 1) % ring.count
        buf.frameLength = 0
        return buf
    }
}
