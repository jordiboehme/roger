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

    /// The first connected device's uid, nil for system default (or when nothing earlier is connected).
    static func resolve(_ list: [InputChoice], connectedUIDs: Set<String>) -> String? {
        for choice in list {
            switch choice {
            case .systemDefault: return nil
            case .device(let uid, _) where connectedUIDs.contains(uid): return uid
            case .device: continue
            }
        }
        return nil
    }
}
