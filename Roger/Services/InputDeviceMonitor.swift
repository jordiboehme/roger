import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "InputDeviceMonitor")

/// Pure decision: warm up when the resolved UID differs from the one last warmed up.
struct MicWarmUpTracker {
    /// `nil` = never warmed. `.some(nil)` = warmed with the system default.
    private(set) var lastWarmedUID: String??

    mutating func shouldWarmUp(resolved: String?) -> Bool {
        guard let last = lastWarmedUID else { return true }
        return last != resolved
    }

    mutating func didWarmUp(resolved: String?) {
        lastWarmedUID = .some(resolved)
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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.simulateChange() }
        }
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

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
