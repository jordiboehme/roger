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

    @Test func startFailureStopsTheHalfStartedTap() {
        struct Denied: Error {}
        let stopped = LockedFlag()
        let recorder = SystemAudioRecorder(makeStream: { throw Denied() }, stopStream: { stopped.set() })
        _ = try? recorder.start()
        #expect(stopped.value)
        #expect(recorder.startedAt == nil)
    }

    @Test func startRecordsWhenTheTapStarted() throws {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        defer { continuation.finish() }
        let before = Date()
        let recorder = SystemAudioRecorder(makeStream: { stream }, stopStream: {})
        try recorder.start()
        let startedAt = try #require(recorder.startedAt)
        #expect(startedAt >= before)
        #expect(startedAt <= Date())
    }

    /// coreaudiod hangs: the stream never finishes. stop() must give up.
    @Test(.timeLimit(.minutes(1)))
    func stopGivesUpWhenTheTapNeverFinishes() async throws {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let recorder = SystemAudioRecorder(makeStream: { stream }, stopStream: {})
        try recorder.start()
        continuation.yield([0.5])
        let clock = ContinuousClock()
        let start = clock.now
        let samples = await recorder.stop(timeout: .milliseconds(200))
        #expect(samples == nil)
        #expect(clock.now - start < .seconds(5))
        continuation.finish()
    }

    @Test func stopWithoutStartReturnsNothing() async {
        let recorder = SystemAudioRecorder(makeStream: { AsyncStream { $0.finish() } }, stopStream: {})
        let samples = await recorder.stop(timeout: .milliseconds(200))
        #expect(samples == [])
    }

    @Test func planSkipsTheTapDuringAMeeting() {
        #expect(SystemAudioRecorder.plan(isLog: true, recordSystemAudio: true, meetingActive: false) == .record)
        #expect(SystemAudioRecorder.plan(isLog: true, recordSystemAudio: true, meetingActive: true) == .unavailable)
        #expect(SystemAudioRecorder.plan(isLog: true, recordSystemAudio: false, meetingActive: true) == .off)
        #expect(SystemAudioRecorder.plan(isLog: false, recordSystemAudio: true, meetingActive: false) == .off)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
