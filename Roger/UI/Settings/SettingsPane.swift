import SwiftUI

/// One page of the settings window, in sidebar order. The raw value is
/// stored as the last pane and names the snapshot files.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case presets
    case microphone
    case model
    case aiProvider
    case files
    case library
    case agents
    case commands
    case permissions
    case about

    /// The blocks of the sidebar, top to bottom.
    enum SidebarGroup: CaseIterable, Hashable {
        case top
        case transcription
        case library
        case bottom

        /// Section header, nil for the blocks without one.
        var title: String? {
            switch self {
            case .top, .bottom: return nil
            case .transcription: return "Transcription"
            case .library: return "Library"
            }
        }

        var panes: [SettingsPane] {
            SettingsPane.allCases.filter { $0.sidebarGroup == self }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .presets: return "Presets"
        case .microphone: return "Microphone"
        case .model: return "Speech Model"
        case .aiProvider: return "Text Model"
        case .files: return "Files"
        case .library: return "Library & Meetings"
        case .agents: return "Agents"
        case .commands: return "Commands"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .presets: return "text.badge.star"
        case .microphone: return "mic"
        case .model: return "waveform"
        case .aiProvider: return "sparkles"
        case .files: return "doc.text"
        case .library: return "books.vertical"
        case .agents: return "point.3.connected.trianglepath.dotted"
        case .commands: return "terminal"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    /// Fill of the rounded square behind the symbol.
    var color: Color {
        switch self {
        case .general: return .gray
        case .presets: return .orange
        case .microphone: return .red
        case .model: return .purple
        case .aiProvider: return .pink
        case .files: return .blue
        case .library: return .brown
        case .agents: return .teal
        case .commands: return .green
        case .permissions: return .indigo
        case .about: return .gray
        }
    }

    var sidebarGroup: SidebarGroup {
        switch self {
        case .general, .presets, .microphone: return .top
        case .model, .aiProvider, .files: return .transcription
        case .library, .agents, .commands: return .library
        case .permissions, .about: return .bottom
        }
    }

    /// A stored pane name. Also takes the tab names of Roger 0.25 and
    /// earlier ("fileTranscription", "recordings").
    init?(storedValue: String) {
        if let pane = SettingsPane(rawValue: storedValue) {
            self = pane
            return
        }
        switch storedValue {
        case "fileTranscription": self = .files
        case "recordings": self = .library
        default: return nil
        }
    }
}
