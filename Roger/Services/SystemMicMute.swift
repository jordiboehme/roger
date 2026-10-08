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
/// whether *it* muted the device and restores on unmute / recording stop /
/// app quit. The hold is also persisted, so a crash or force quit is undone on
/// the next launch. A mute Roger doesn't hold (left over from an earlier
/// session or set elsewhere) is released when dictation starts, see
/// `releaseStaleMute()`.
@MainActor
@Observable
final class SystemMicMute {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "SystemMicMute")

    /// True while Roger is holding the input device muted.
    private(set) var isMuted = false

    private let appState: AppState

    /// How the current mute was achieved, captured so we can undo it exactly.
    /// Undoing a HAL mute always unmutes: a device that was already muted
    /// when Roger took the hold was a stale mute, not a state worth keeping.
    private enum Applied {
        case mute(device: AudioDeviceID)
        case volume(device: AudioDeviceID, previous: Float32)
    }
    private var applied: Applied?

    /// The hold as written to UserDefaults, keyed by device UID because
    /// `AudioDeviceID`s don't survive a relaunch.
    private struct PendingRestore: Codable {
        enum Kind: String, Codable { case mute, volume }
        let deviceUID: String
        let kind: Kind
        let previousVolume: Float32?
    }
    private static let pendingRestoreKey = "systemMicMutePendingRestore"

    init(appState: AppState) {
        self.appState = appState
        restorePendingFromPreviousRun()
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
        if readMute(device) != nil, setMute(device, true) {
            applied = .mute(device: device)
            persistPendingRestore(device: device, kind: .mute, previousVolume: nil)
            isMuted = true
            Self.logger.notice("Input device \(device, privacy: .public) muted (HAL mute)")
            return
        }
        // Fallback: drop the input volume to zero and restore it on unmute.
        if let previousVolume = readVolume(device), setVolume(device, 0) {
            applied = .volume(device: device, previous: previousVolume)
            persistPendingRestore(device: device, kind: .volume, previousVolume: previousVolume)
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
        case let .mute(device):
            _ = setMute(device, false)
        case let .volume(device, previous):
            _ = setVolume(device, previous)
        }
        self.applied = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
        Self.logger.notice("Input device unmuted (restored prior state)")
    }

    /// Unmutes the target input device if it is muted at the HAL level while
    /// Roger holds no mute. A muted device delivers silence, so dictation
    /// would record nothing, and nothing on screen tells the user why.
    /// Returns true when it unmuted.
    @discardableResult
    func releaseStaleMute() -> Bool {
        guard !isMuted, let device = targetInputDevice(), readMute(device) == 1 else { return false }
        guard setMute(device, false) else { return false }
        Self.logger.notice("Input device \(device, privacy: .public) was muted outside Roger's hold — unmuted for dictation")
        return true
    }

    // MARK: - Crash recovery

    private func persistPendingRestore(device: AudioDeviceID, kind: PendingRestore.Kind, previousVolume: Float32?) {
        guard let uid = AudioDeviceLookup.uid(for: device) else { return }
        let pending = PendingRestore(deviceUID: uid, kind: kind, previousVolume: previousVolume)
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingRestoreKey)
        }
    }

    /// Undoes a hold the previous run never released (crash, force quit,
    /// power loss). The device may be gone by now; then the record is dropped.
    private func restorePendingFromPreviousRun() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.pendingRestoreKey) else { return }
        defaults.removeObject(forKey: Self.pendingRestoreKey)
        guard let pending = try? JSONDecoder().decode(PendingRestore.self, from: data),
              let device = AudioDeviceLookup.deviceID(forUID: pending.deviceUID)
        else { return }
        switch pending.kind {
        case .mute:
            _ = setMute(device, false)
        case .volume:
            if let previous = pending.previousVolume { _ = setVolume(device, previous) }
        }
        Self.logger.notice("Restored input device \(device, privacy: .public) left muted by a previous run")
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
