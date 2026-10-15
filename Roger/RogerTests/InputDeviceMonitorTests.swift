import Foundation
import Testing
@testable import Roger

struct InputDeviceMonitorTests {
    @Test func trackerWarmsUpWhenNeverWarmed() {
        var tracker = MicWarmUpTracker()
        let r1 = tracker.shouldWarmUp(resolved: "a")
        #expect(r1)
        let r2 = tracker.shouldWarmUp(resolved: nil)
        #expect(r2)
    }

    @Test func trackerSkipsTheSameUID() {
        var tracker = MicWarmUpTracker()
        tracker.didWarmUp(resolved: "a")
        let r3 = tracker.shouldWarmUp(resolved: "a")
        #expect(!r3)
        let r4 = tracker.shouldWarmUp(resolved: "b")
        #expect(r4)
        tracker.didWarmUp(resolved: nil)
        let r5 = tracker.shouldWarmUp(resolved: nil)
        #expect(!r5)
    }

    @Test func trackerTreatsNilAndDeviceAsDifferent() {
        var tracker = MicWarmUpTracker()
        tracker.didWarmUp(resolved: nil)
        let r6 = tracker.shouldWarmUp(resolved: "a")
        #expect(r6)
        tracker.didWarmUp(resolved: "a")
        let r7 = tracker.shouldWarmUp(resolved: nil)
        #expect(r7)
    }

    @MainActor
    @Test func debouncesBurstsIntoOneCall() async throws {
        var count = 0
        let monitor = InputDeviceMonitor(debounce: .milliseconds(200)) { count += 1 }
        monitor.simulateChange()
        try await Task.sleep(for: .milliseconds(40))
        monitor.simulateChange()
        try await Task.sleep(for: .milliseconds(40))
        monitor.simulateChange()
        try await Task.sleep(for: .milliseconds(500))
        #expect(count == 1)
    }
}
