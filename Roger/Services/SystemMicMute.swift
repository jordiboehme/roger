import CoreAudio
import Foundation
import Observation
import os

/// Mutes / unmutes the microphone at the Core Audio HAL level, so the mute
/// applies **system-wide** — Teams, Zoom, Roger, every client of the device.
///
/// Used during meeting recordings: muting yields silence for the meeting app
/// *and* for Roger's own `mic.m4a` (the device delivers zeroed buffers), so no
/// recording-pipeline change is needed and the mic timeline stays intact.
///
/// HAL device state persists after our process exits, so Roger remembers
/// whether *it* muted the device and the prior value, and restores on
/// unmute / recording stop / app quit — the user is never left stranded muted.
@MainActor
@Observable
final class SystemMicMute {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "SystemMicMute")

    /// True while Roger is holding the input device muted.
    private(set) var isMuted = false

    private let appState: AppState

    /// How the current mute was achieved, captured so we can undo it exactly.
    private enum Applied {
        case mute(device: AudioDeviceID, previous: UInt32)
        case volume(device: AudioDeviceID, previous: Float32)
    }
    private var applied: Applied?

    init(appState: AppState) {
        self.appState = appState
    }

    func toggle() {
        if isMuted { unmute() } else { mute() }
    }

    func mute() {
        guard !isMuted else { return }
        guard let device = targetInputDevice() else {
            Self.logger.error("No input device available to mute")
            return
        }
        // Primary: the device's own input mute.
        if let previous = readMute(device), setMute(device, true) {
            applied = .mute(device: device, previous: previous)
            isMuted = true
            Self.logger.notice("Input device \(device, privacy: .public) muted (HAL mute)")
            return
        }
        // Fallback: drop the input volume to zero and restore it on unmute.
        if let previousVolume = readVolume(device), setVolume(device, 0) {
            applied = .volume(device: device, previous: previousVolume)
            isMuted = true
            Self.logger.notice("Input device \(device, privacy: .public) muted (volume-0 fallback)")
            return
        }
        Self.logger.error("Input device \(device, privacy: .public) supports neither settable mute nor input volume — cannot mute")
    }

    func unmute() {
        defer { isMuted = false }
        guard let applied else { return }
        switch applied {
        case let .mute(device, previous):
            _ = setMute(device, previous != 0)
        case let .volume(device, previous):
            _ = setVolume(device, previous)
        }
        self.applied = nil
        Self.logger.notice("Input device unmuted (restored prior state)")
    }

    /// Restore the device if Roger currently holds it muted. Safe to call
    /// repeatedly — used on recording stop and app termination.
    func restoreIfNeeded() {
        if isMuted { unmute() }
    }

    // MARK: - Target device

    /// The mic the user records / speaks into: their explicitly selected input
    /// if set, otherwise the system default input.
    private func targetInputDevice() -> AudioDeviceID? {
        if let uid = appState.selectedInputDeviceUID,
           let id = AudioDeviceLookup.deviceID(forUID: uid) {
            return id
        }
        return AudioDeviceLookup.systemDefaultInputID
    }

    // MARK: - Device mute property

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Current mute value, or nil if the device has no *settable* input mute.
    private func readMute(_ device: AudioDeviceID) -> UInt32? {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            Self.logger.error("setMute failed: \(CoreAudioHelpers.errorString(status), privacy: .public)")
        }
        return status == noErr
    }

    // MARK: - Input volume fallback

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func readVolume(_ device: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private func setVolume(_ device: AudioDeviceID, _ value: Float32) -> Bool {
        var address = volumeAddress()
        var newValue = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &newValue)
        return status == noErr
    }
}
