import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "InputDeviceMonitor")

/// Pure decision: warm up when the device Roger records from differs from
/// the one last warmed up. Keyed on the actual device (for System default the
/// UID of the macOS default input), so a change of the macOS default input
/// warms up too.
struct MicWarmUpTracker {
    /// `nil` = never warmed. `.some(nil)` = warmed while Core Audio named no device.
    private(set) var lastWarmedUID: String??

    func shouldWarmUp(device: String?) -> Bool {
        guard let last = lastWarmedUID else { return true }
        return last != device
    }

    /// Call only after a warm-up that ran to its end.
    mutating func didWarmUp(device: String?) {
        lastWarmedUID = .some(device)
    }
}

/// Listens to Core Audio's device list and default input. Calls `onChange`
/// on the main actor, debounced, after the last change.
@MainActor
final class InputDeviceMonitor {
    private let debounce: Duration
    private let onChange: @MainActor () -> Void
    private var debounceTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.jordiboehme.roger.input-device-monitor")
    private var listener: AudioObjectPropertyListenerBlock?
    private var started = false

    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    init(debounce: Duration = .seconds(1), onChange: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard !started else { return }
        started = true
        let block = Self.makeListener(self)
        listener = block
        for selector in Self.selectors {
            var address = Self.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status != noErr {
                logger.error("Could not listen to audio property \(selector): \(status)")
            }
        }
    }

    func stop() {
        guard started, let block = listener else { return }
        started = false
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        listener = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Restarts the debounce. Core Audio changes arrive here too; tests call it directly.
    func simulateChange() {
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.onChange()
        }
    }

    /// Built outside the main actor: Core Audio calls the block on `queue`,
    /// so it must not be inferred as main-actor isolated.
    private nonisolated static func makeListener(_ monitor: InputDeviceMonitor) -> AudioObjectPropertyListenerBlock {
        { [weak monitor] _, _ in
            Task { @MainActor in monitor?.simulateChange() }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
