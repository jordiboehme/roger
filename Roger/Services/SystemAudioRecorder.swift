import AVFoundation
import Foundation

/// Collects system audio for one log recording, in memory, 16 kHz mono.
/// Owns the tap (through the two closures), the consumer task and the
/// sample buffer.
final class SystemAudioRecorder: @unchecked Sendable {
    private let makeStream: () throws -> AsyncStream<[Float]>
    private let stopStream: () -> Void
    private let lock = NSLock()
    private var samples: [Float] = []
    private var consumer: Task<Void, Never>?

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
        let task = Task { [weak self] in
            for await chunk in stream {
                self?.append(chunk)
            }
        }
        lock.withLock { consumer = task }
    }

    /// Stops, waits for the consumer and returns everything collected.
    func stop() async -> [Float] {
        stopStream()
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { consumer = nil }
            return consumer
        }
        await task?.value
        return lock.withLock { samples }
    }

    private func append(_ chunk: [Float]) {
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
