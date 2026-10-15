import Foundation

/// One entry of the microphone priority list (Settings > Microphone).
enum InputChoice: Codable, Hashable, Identifiable {
    /// Whatever macOS uses as the default input. Always in the list once.
    case systemDefault
    /// A device by Core Audio UID. `name` is the last known name, for display.
    case device(uid: String, name: String)

    var id: String {
        switch self {
        case .systemDefault: return "system-default"
        case .device(let uid, _): return uid
        }
    }

    /// Migrates the 0.26 setting.
    static func migrated(selectedUID: String?, nameForUID: (String) -> String?) -> [InputChoice] {
        guard let uid = selectedUID else { return [.systemDefault] }
        return [.device(uid: uid, name: nameForUID(uid) ?? uid), .systemDefault]
    }

    /// Ensures exactly one .systemDefault (appended when missing, duplicates dropped) and no duplicate uids.
    static func repaired(_ list: [InputChoice]) -> [InputChoice] {
        var seen = Set<String>()
        var result = list.filter { seen.insert($0.id).inserted }
        if !result.contains(.systemDefault) { result.append(.systemDefault) }
        return result
    }

    /// The list Roger starts with: the stored list (repaired), or the 0.26
    /// setting migrated when nothing usable is stored. `write` is true when
    /// the result differs from what is stored and must be saved.
    /// `nameForUID` is only asked when a 0.26 device is migrated.
    static func load(stored: Data?, legacyUID: String?, nameForUID: (String) -> String?) -> (list: [InputChoice], write: Bool) {
        if let stored, let decoded = try? JSONDecoder().decode([InputChoice].self, from: stored) {
            let list = repaired(decoded)
            return (list, list != decoded)
        }
        return (migrated(selectedUID: legacyUID, nameForUID: nameForUID), true)
    }

    /// The first connected device's uid, nil for system default (or when nothing earlier is connected).
    static func resolve(_ list: [InputChoice], connectedUIDs: Set<String>) -> String? {
        resolve(list, isConnected: connectedUIDs.contains)
    }

    /// Same, asking `isConnected` only for the device entries before
    /// `.systemDefault`. A list that starts with `.systemDefault` asks nothing.
    static func resolve(_ list: [InputChoice], isConnected: (String) -> Bool) -> String? {
        for choice in list {
            switch choice {
            case .systemDefault: return nil
            case .device(let uid, _) where isConnected(uid): return uid
            case .device: continue
            }
        }
        return nil
    }
}
