import CoreGraphics
import Foundation

enum CapsModifier: String, Codable, CaseIterable, Identifiable {
    case shift
    case option
    case control
    case command

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        }
    }

    var displayName: String {
        switch self {
        case .shift: return "Shift"
        case .option: return "Option"
        case .control: return "Control"
        case .command: return "Command"
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }

    /// Returns the single active modifier in the event flags, or nil if none or multiple are held.
    static func from(_ flags: CGEventFlags) -> CapsModifier? {
        let held = allCases.filter { flags.contains($0.eventFlag) }
        return held.count == 1 ? held.first : nil
    }
}
