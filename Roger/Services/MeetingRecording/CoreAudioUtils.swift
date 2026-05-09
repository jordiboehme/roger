import AudioToolbox
import CoreAudio
import Foundation

/// Small helpers for working with the Core Audio HAL property API.
///
/// Adapted from `insidegui/AudioCap` (MIT). We keep a thin standalone copy
/// rather than vendoring the whole project so future upstream improvements
/// can be folded in selectively.
enum CoreAudioHelpers {
    /// Returns a four-character-code string for an OSStatus, or its decimal
    /// value if not printable. Useful for logging Core Audio errors.
    static func errorString(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: Int32(status))
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8(raw & 0xff)
        ]
        if bytes.allSatisfy({ (0x20 ... 0x7e).contains($0) }),
           let printable = String(bytes: bytes, encoding: .ascii) {
            return "'" + printable + "'"
        }
        return String(status)
    }
}

extension AudioObjectID {
    /// The system-wide AudioObject root.
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// AudioObjectID of the current default output device, or 0 if Core Audio
    /// can't tell us. Read this any time the system output may have changed
    /// (e.g. headphone plug events).
    static func readDefaultSystemOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID.systemObject,
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    /// Translates a process identifier to the AudioObject the HAL uses to
    /// identify it inside `CATapDescription`. Returns 0 on failure.
    static func translatePID(_ pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var processID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID.systemObject,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &qualifier,
            &size,
            &processID
        )
        return status == noErr ? processID : 0
    }

    /// Reads a C-struct property into `T` and returns it, or nil on failure.
    func readProperty<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size = UInt32(MemoryLayout<T>.size)
        let buf = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buf.deallocate() }
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buf)
        guard status == noErr else { return nil }
        return buf.pointee
    }
}
