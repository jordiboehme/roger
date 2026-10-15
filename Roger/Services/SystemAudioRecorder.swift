import AVFoundation
import Foundation

/// Collects system audio for one log recording, in memory, 16 kHz mono.
/// Owns the tap (through the two closures), the consumer task and the
/// sample buffer.
final class SystemAudioRecorder: @unchecked Sendable {
    /// What a dictation does about system audio.
    enum Plan: Equatable {
        /// Not asked for (not a log, or the preset does not record system audio).
        case off
        /// Start the tap.
        case record
        /// Asked for but not possible now: the log is saved with the mic only
        /// and the "system audio unavailable" note.
        case unavailable
    }

    /// A log with system audio while a meeting records takes the mic only:
    /// the meeting already records the other side, and a second tap would
    /// copy the meeting audio into the log.
    static func plan(isLog: Bool, recordSystemAudio: Bool, meetingActive: Bool) -> Plan {
        guard isLog, recordSystemAudio else { return .off }
        return meetingActive ? .unavailable : .record
    }

    /// How long `stop()` waits for the tap to drain. A wedged coreaudiod can
    /// keep the tap from finishing; the log is then saved with the mic only.
    static let stopTimeout: Duration = .seconds(5)

    private let makeStream: () throws -> AsyncStream<[Float]>
    private let stopStream: () -> Void
    private let lock = NSLock()
    private var samples: [Float] = []
    private var consumer: Task<Void, Never>?
    private var started: Date?

    init(makeStream: @escaping () throws -> AsyncStream<[Float]>, stopStream: @escaping () -> Void) {
        self.makeStream = makeStream
        self.stopStream = stopStream
    }

    /// The production recorder on top of SystemAudioTap.
    static func live() -> SystemAudioRecorder {
        let tap = SystemAudioTap()
        return SystemAudioRecorder(
            makeStream: {
                let buffers = try tap.startStreaming()
                return AsyncStream { continuation in
                    let task = Task {
                        for await buffer in buffers {
                            continuation.yield(Self.floats(buffer.buffer))
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            // `SystemAudioTap.stop()` finishes the stream on its writer
            // queue, so the consumer ends after the last buffer.
            stopStream: { tap.stop() }
        )
    }

    /// When the tap started delivering, nil before `start()` succeeded.
    /// Used to line the system track up with the mic track.
    var startedAt: Date? {
        lock.withLock { started }
    }

    /// Throws when the tap cannot start (permission, no output device).
    func start() throws {
        let stream: AsyncStream<[Float]>
        do {
            stream = try makeStream()
        } catch {
            // A half-started tap (created, then failed) must not stay alive.
            stopStream()
            throw error
        }
        let now = Date()
        let task = Task { [weak self] in
            for await chunk in stream {
                self?.append(chunk)
            }
        }
        lock.withLock {
            consumer = task
            started = now
        }
    }

    /// Stops, waits for the consumer and returns everything collected.
    /// Returns nil when the tap has not finished within `timeout`; the
    /// consumer is cancelled then, so nothing stays parked.
    func stop(timeout: Duration = SystemAudioRecorder.stopTimeout) async -> [Float]? {
        stopStream()
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { consumer = nil }
            return consumer
        }
        if let task, !(await Self.wait(for: task, timeout: timeout)) {
            task.cancel()
            return nil
        }
        return lock.withLock { samples }
    }

    /// True when `task` finished within `timeout`. Never waits longer, even
    /// when the task never ends.
    private static func wait(for task: Task<Void, Never>, timeout: Duration) async -> Bool {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: false) }
            }
            Task {
                await task.value
                timer.cancel()
                if once.claim() { continuation.resume(returning: true) }
            }
        }
    }

    private func append(_ chunk: [Float]) {
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

/// Lets exactly one of two racing tasks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
