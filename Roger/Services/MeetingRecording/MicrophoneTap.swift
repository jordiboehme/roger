import AVFoundation
import CoreAudio
import Foundation
import os

/// Streaming counterpart of `AudioCaptureService` for the meeting-recording
/// path. Where `AudioCaptureService` accumulates a one-shot `[Float]` buffer
/// for dictation, `MicrophoneTap` exposes an unbounded `AsyncStream` of
/// `AVAudioPCMBuffer`s converted to 16 kHz mono float32 — symmetrical with
/// `SystemAudioTap`. Format conversion happens off the audio thread on a
/// dedicated serial queue.
final class MicrophoneTap: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MicrophoneTap")

    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let writerQueue = DispatchQueue(label: "com.jordiboehme.roger.mictap.writer", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var continuation: AsyncStream<SendableAudioBuffer>.Continuation?

    /// UID of the input device to pin, or nil for system default.
    var preferredInputUID: String?

    /// Starts capture and returns the converted buffer stream.
    func startStreaming() throws -> AsyncStream<SendableAudioBuffer> {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MicrophoneTapError.permissionDenied
        }

        let inputNode = engine.inputNode
        if let uid = preferredInputUID, let deviceID = AudioDeviceLookup.deviceID(forUID: uid) {
            applyDeviceID(deviceID, to: inputNode)
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            throw MicrophoneTapError.noInputDevice
        }
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw MicrophoneTapError.converterUnavailable
        }
        self.converter = converter
        self.inputFormat = nativeFormat

        let stream = AsyncStream<SendableAudioBuffer>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.continuation = continuation
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nativeFormat) { [weak self] buffer, _ in
            self?.writerQueue.async {
                self?.deliver(buffer, targetFormat: targetFormat)
            }
        }

        engine.prepare()
        try engine.start()
        Self.logger.notice("MicrophoneTap streaming (\(nativeFormat.sampleRate, privacy: .public) Hz × \(nativeFormat.channelCount, privacy: .public)ch → \(Self.targetSampleRate, privacy: .public) Hz mono)")
        return stream
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        writerQueue.async { [weak self] in
            self?.continuation?.finish()
            self?.continuation = nil
            self?.converter = nil
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter, let inputFormat, let continuation else { return }
        let ratio = Self.targetSampleRate / inputFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            Self.logger.error("Mic conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if status == .error { return }
        if convertedBuffer.frameLength > 0 {
            _ = continuation.yield(SendableAudioBuffer(buffer: convertedBuffer))
        }
    }

    private func applyDeviceID(_ deviceID: AudioDeviceID, to inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}

enum MicrophoneTapError: LocalizedError {
    case permissionDenied
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied — grant permission in System Settings › Privacy & Security."
        case .noInputDevice:
            return "No audio input device available."
        case .converterUnavailable:
            return "Couldn't build the audio format converter."
        }
    }
}
