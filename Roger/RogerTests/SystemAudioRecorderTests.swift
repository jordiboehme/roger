import Foundation
import Testing
@testable import Roger

struct SystemAudioRecorderTests {
    @Test func collectsAllChunksInOrder() async throws {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let stopped = LockedFlag()
        let recorder = SystemAudioRecorder(makeStream: { stream }, stopStream: { stopped.set(); continuation.finish() })
        try recorder.start()
        continuation.yield([0.1, 0.2])
        continuation.yield([0.3])
        let samples = await recorder.stop()
        #expect(samples == [0.1, 0.2, 0.3])
        #expect(stopped.value)
    }

    @Test func startFailureThrows() {
        struct Denied: Error {}
        let recorder = SystemAudioRecorder(makeStream: { throw Denied() }, stopStream: {})
        #expect(throws: Denied.self) { try recorder.start() }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
