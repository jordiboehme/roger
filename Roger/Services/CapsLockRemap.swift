import Foundation

/// Whether Caps Lock sends F18 (Roger's dictation key) through a hidutil
/// key mapping. `HotkeyManager.remapCapsLockToF18()` sets that mapping.
enum CapsLockRemap {
    /// HID usages of Caps Lock (0x700000039) and F18 (0x70000006D).
    static let capsLockUsage: UInt64 = 0x7_0000_0039
    static let f18Usage: UInt64 = 0x7_0000_006D

    /// True when the output of `hidutil property --get UserKeyMapping` has a
    /// mapping from Caps Lock to F18. hidutil prints one block per keyboard
    /// with the numbers in decimal; hex is accepted too.
    static func isActive(hidutilOutput: String) -> Bool {
        let compact = String(hidutilOutput.filter { !$0.isWhitespace }).lowercased()
        let sources = ["hidkeyboardmodifiermappingsrc=\(capsLockUsage);", "hidkeyboardmodifiermappingsrc=0x700000039;"]
        let targets = ["hidkeyboardmodifiermappingdst=\(f18Usage);", "hidkeyboardmodifiermappingdst=0x70000006d;"]
        return compact.split(separator: "}").contains { block in
            sources.contains { block.contains($0) } && targets.contains { block.contains($0) }
        }
    }

    /// Asks hidutil, off the main actor. False when hidutil cannot run.
    static func isActiveNow() async -> Bool {
        await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            task.arguments = ["property", "--get", "UserKeyMapping"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                return false
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return isActive(hidutilOutput: String(decoding: data, as: UTF8.self))
        }.value
    }
}
