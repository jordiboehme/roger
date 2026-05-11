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

    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private(set) var droppedBuffers = 0
    private var totalInputFrames: UInt64 = 0
    private var totalOutputFrames: UInt64 = 0
    private var callbackCount: UInt64 = 0
    private var streamingStartedAt: Date?

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
        self.targetFormat = targetFormat
        self.converter = converter
        self.totalInputFrames = 0
        self.totalOutputFrames = 0
        self.callbackCount = 0
        self.streamingStartedAt = Date()

        let stream = AsyncStream<SendableAudioBuffer>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable _ in
                Self.logger.info("System audio stream consumer terminated")
            }
        }

        tap.bufferHandler = { [weak self] bufferList, _ in
            self?.ingest(bufferList: bufferList, inputFormat: inputFormat)
        }

        let inASBD = inputFormat.streamDescription.pointee
        let ratio = Self.targetSampleRate / inputFormat.sampleRate
        Self.logger.notice("SystemAudioTap streaming: input=\(inASBD.mSampleRate, privacy: .public) Hz × \(inASBD.mChannelsPerFrame, privacy: .public)ch (mBytesPerFrame=\(inASBD.mBytesPerFrame, privacy: .public), interleaved=\(inputFormat.isInterleaved, privacy: .public)) → \(Self.targetSampleRate, privacy: .public) Hz mono, expected ratio=\(ratio, privacy: .public)")
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
            self?.streamingStartedAt = nil
        }
    }

    /// Called on the IOProc dispatch queue (real-time priority). Wraps the
    /// raw `AudioBufferList` into an `AVAudioPCMBuffer` whose samples it
    /// COPIES into a stable backing buffer (the bufferList memory is only
    /// valid for the duration of this call), then hops to the writer queue
    /// for conversion + delivery.
    private func ingest(bufferList: UnsafePointer<AudioBufferList>, inputFormat: AVAudioFormat) {
        let sourceABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard sourceABL.count > 0 else { return }
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frames = AVAudioFrameCount(Int(sourceABL[0].mDataByteSize) / bytesPerFrame)
        guard frames > 0 else { return }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }

        // Copy every plane of the source list — for non-interleaved stereo
        // (the default process-tap layout) `sourceABL.count == 2`; for
        // interleaved formats it's a single buffer with both channels packed.
        let destinationABL = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        let planeCount = min(destinationABL.count, sourceABL.count)
        for plane in 0 ..< planeCount {
            let dst = destinationABL[plane]
            let src = sourceABL[plane]
            guard let dstData = dst.mData, let srcData = src.mData else { continue }
            let bytes = min(Int(dst.mDataByteSize), Int(src.mDataByteSize))
            memcpy(dstData, srcData, bytes)
        }
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
        guard let converter, let inputFormat, let targetFormat, let continuation else {
            droppedBuffers += 1
            if droppedBuffers % 100 == 0 {
                Self.logger.warning("System audio dropped \(self.droppedBuffers, privacy: .public) buffers cumulative")
            }
            return
        }
        // Size the destination buffer to match the converter's ratio, like
        // MicrophoneTap does. Over-sizing the destination (the previous
        // fixed-capacity ring) makes the SRC produce a different number of
        // frames per packet than the input's real-time duration, which
        // shows up as a pitch shift on playback.
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = max(1, AVAudioFrameCount(Double(input.frameLength) * ratio))
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
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

        totalInputFrames += UInt64(input.frameLength)
        totalOutputFrames += UInt64(convertedBuffer.frameLength)
        callbackCount += 1
        if callbackCount == 1 {
            let elapsed = streamingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            Self.logger.notice("First system audio packet: input=\(input.frameLength, privacy: .public) frames, output=\(convertedBuffer.frameLength, privacy: .public) frames, \(elapsed, privacy: .public)s since stream start")
        } else if callbackCount.isMultiple(of: 100) {
            let measured = Double(totalOutputFrames) / Double(max(1, totalInputFrames))
            Self.logger.debug("System audio cumulative ratio: measured=\(measured, privacy: .public) expected=\(ratio, privacy: .public) (in=\(self.totalInputFrames, privacy: .public) out=\(self.totalOutputFrames, privacy: .public))")
        }

        if convertedBuffer.frameLength > 0 {
            // Continuation buffers internally; the dropOldest policy means a
            // slow consumer just shows up as a `droppedBuffers` count.
            let sent = continuation.yield(SendableAudioBuffer(buffer: convertedBuffer))
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
}
