import KeyboardShortcuts
import SwiftUI

/// Every settings pane is one of these: a grouped form with the standard
/// margins, section headers and footers.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

/// Row title with an optional note under it.
struct SettingsLabel: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = .secondary
    /// Paths: one line, cut in the middle, full text as a tooltip.
    var truncatesNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let note {
                if truncatesNote {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(noteColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(note)
                } else {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(noteColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Label and note on the leading side, a control on the trailing side.
struct SettingsRow<Control: View>: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = .secondary
    var truncatesNote = false
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            SettingsLabel(title: title, note: note, noteColor: noteColor, truncatesNote: truncatesNote)
        }
    }
}

/// A switch row with an optional note.
struct SettingsToggle: View {
    let title: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(title: title, note: note)
        }
        .toggleStyle(.switch)
    }
}

/// A notice at the top of a pane: symbol, message and one action.
struct SettingsBanner: View {
    let symbol: String
    let tint: Color
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.large)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
        }
    }
}

/// A colored dot with a short status text.
struct SettingsStatus: View {
    enum Level {
        case good
        case warning
        case bad
        case unknown

        var color: Color {
            switch self {
            case .good: return .green
            case .warning: return .orange
            case .bad: return .red
            case .unknown: return .gray
            }
        }
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// A duration with its unit and a stepper.
struct SettingsDurationStepper: View {
    @Binding var seconds: TimeInterval
    let range: ClosedRange<TimeInterval>
    let step: TimeInterval

    var body: some View {
        Stepper(value: $seconds, in: range, step: step) {
            Text(SettingsFormat.duration(seconds))
                .monospacedDigit()
        }
    }
}

/// Note color for a test result: green for "OK...", red otherwise.
enum SettingsResultColor {
    static func color(for result: String?) -> Color {
        guard let result else { return .secondary }
        return result.hasPrefix("OK") ? .green : .red
    }
}

/// A global shortcut recorder. F18 is refused: it is the dictation key.
struct SettingsShortcutRecorder: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        KeyboardShortcuts.Recorder(for: name)
            .shortcutValidation { shortcut in
                if shortcut.key == .f18 {
                    return .disallow(reason: "F18 is Roger's dictation hotkey (Caps Lock).")
                }
                return .allow
            }
    }
}

/// Preset menu for meetings and files: presets with AI steps are shown
/// but cannot be picked, so these transcripts never reach an AI provider.
struct LocalPresetMenu: View {
    let title: String
    var note: String? = nil
    let presets: [DictationPreset]
    @Binding var selection: UUID
    /// The preset in use (the fallback when the stored one needs AI).
    let currentName: String

    var body: some View {
        let checked = Self.effectiveID(selection: selection, presets: presets)
        SettingsRow(title: title, note: note) {
            Menu(currentName) {
                ForEach(presets) { preset in
                    Button {
                        if !preset.requiresAI { selection = preset.id }
                    } label: {
                        if preset.id == checked {
                            Label(menuTitle(preset), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(preset))
                        }
                    }
                    .disabled(preset.requiresAI)
                }
            }
            .fixedSize()
        }
    }

    /// The preset in use: the stored one when it exists and needs no AI,
    /// else Plain (the same fallback as the AppState resolvers).
    static func effectiveID(selection: UUID, presets: [DictationPreset]) -> UUID {
        if let preset = presets.first(where: { $0.id == selection }), !preset.requiresAI {
            return preset.id
        }
        return DictationPreset.plain.id
    }

    private func menuTitle(_ preset: DictationPreset) -> String {
        preset.requiresAI ? "\(preset.name) (needs AI)" : preset.name
    }
}
