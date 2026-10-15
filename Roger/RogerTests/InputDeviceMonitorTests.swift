import Foundation
import Testing
@testable import Roger

struct InputDeviceMonitorTests {
    @Test func trackerWarmsUpWhenNeverWarmed() {
        let tracker = MicWarmUpTracker()
        #expect(tracker.shouldWarmUp(device: "a"))
        #expect(tracker.shouldWarmUp(device: nil))
    }

    @Test func trackerSkipsTheSameDevice() {
        var tracker = MicWarmUpTracker()
        tracker.didWarmUp(device: "a")
        #expect(!tracker.shouldWarmUp(device: "a"))
        #expect(tracker.shouldWarmUp(device: "b"))
        tracker.didWarmUp(device: nil)
        #expect(!tracker.shouldWarmUp(device: nil))
    }

    /// System default stays first in the list, macOS switches its default
    /// input from the built-in mic to a headset: that is a new device.
    @Test func aNewMacOSDefaultInputWarmsUp() {
        var tracker = MicWarmUpTracker()
        tracker.didWarmUp(device: AudioDeviceLookup.actualInputUID(resolved: nil, defaultUID: { "builtin" }))
        let after = AudioDeviceLookup.actualInputUID(resolved: nil, defaultUID: { "headset" })
        #expect(tracker.shouldWarmUp(device: after))
        let same = AudioDeviceLookup.actualInputUID(resolved: nil, defaultUID: { "builtin" })
        #expect(!tracker.shouldWarmUp(device: same))
    }

    /// One call for a burst of changes. Polls instead of trusting one sleep,
    /// so a slow test machine does not fail it.
    @MainActor
    @Test func debouncesBurstsIntoOneCall() async throws {
        var count = 0
        let monitor = InputDeviceMonitor(debounce: .milliseconds(300)) { count += 1 }
        monitor.simulateChange()
        try await Task.sleep(for: .milliseconds(20))
        monitor.simulateChange()
        try await Task.sleep(for: .milliseconds(20))
        monitor.simulateChange()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while count == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(count == 1)
        try await Task.sleep(for: .milliseconds(450))
        #expect(count == 1)
    }
}

struct MicMuteTargetTests {
    @MainActor
    @Test func aRunningMeetingKeepsItsDevice() {
        let uid = SystemMicMute.targetUID(meetingUID: "webcam", resolve: {
            Issue.record("the priority list must not be asked during a meeting")
            return "headset"
        })
        #expect(uid == "webcam")
    }

    @MainActor
    @Test func withoutAMeetingThePriorityListDecides() {
        #expect(SystemMicMute.targetUID(meetingUID: nil, resolve: { "headset" }) == "headset")
        #expect(SystemMicMute.targetUID(meetingUID: nil, resolve: { nil }) == nil)
    }

    @Test func actualInputUIDUsesTheDefaultOnlyForSystemDefault() {
        #expect(AudioDeviceLookup.actualInputUID(resolved: "usb", defaultUID: {
            Issue.record("default asked although a device resolved")
            return "builtin"
        }) == "usb")
        #expect(AudioDeviceLookup.actualInputUID(resolved: nil, defaultUID: { "builtin" }) == "builtin")
        #expect(AudioDeviceLookup.actualInputUID(resolved: nil, defaultUID: { nil }) == nil)
    }
}
