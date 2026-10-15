import CoreAudio
import Foundation

enum AudioDeviceLookup {
    struct InputDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let deviceID: AudioDeviceID
    }

    static func availableInputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let fetchStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        )
        guard fetchStatus == noErr else { return [] }

        return ids.compactMap { id -> InputDevice? in
            guard hasInputChannels(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(id: uid, name: name, deviceID: id)
        }
    }

    /// Asks Core Audio for the device list only when a device entry comes
    /// before System default, and then only once.
    static func resolveInput(_ list: [InputChoice]) -> String? {
        var connected: Set<String>?
        return InputChoice.resolve(list) { uid in
            let set = connected ?? Set(availableInputs().map(\.id))
            connected = set
            return set.contains(uid)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        availableInputs().first { $0.id == uid }?.deviceID
    }

    static func uid(for id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    static var systemDefaultInputID: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        )
        return status == noErr ? id : nil
    }

    /// UID of the macOS default input, nil when Core Audio has none.
    static var systemDefaultInputUID: String? {
        systemDefaultInputID.flatMap(uid(for:))
    }

    /// The device a capture really uses: the resolved UID, or for the system
    /// default the UID of the current macOS default input. `defaultUID` is
    /// only asked when `resolved` is nil.
    static func actualInputUID(resolved: String?, defaultUID: () -> String? = { systemDefaultInputUID }) -> String? {
        resolved ?? defaultUID()
    }

    static var systemDefaultInputName: String? {
        guard let id = systemDefaultInputID else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }
}
