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

/// A multi-line text field with its title above it, for prompts.
struct SettingsTextEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 60)
                .accessibilityLabel(title)
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

/// What to do when a microphone test ran but macOS sent no audio (the
/// coreaudiod wedge). Shared by the Microphone and Permissions panes.
enum SettingsStuckAudio {
    static let advice = "Relaunch Roger. If it happens again, run sudo killall coreaudiod in Terminal or restart the Mac."
}

/// The outcome of a Test button: a short sentence and whether it worked.
struct SettingsTestResult: Equatable {
    let text: String
    let succeeded: Bool

    static func success(_ text: String) -> SettingsTestResult { .init(text: text, succeeded: true) }
    static func failure(_ text: String) -> SettingsTestResult { .init(text: text, succeeded: false) }

    /// A failure with a system error: "Failed: <reason>."
    static func failure(_ error: Error) -> SettingsTestResult {
        let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return .failure("Failed: \(reason).")
    }

    /// Note color: green when it worked, red when not, gray without a result.
    static func color(for result: SettingsTestResult?) -> Color {
        guard let result else { return .secondary }
        return result.succeeded ? .green : .red
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
    /// The preset in use, from `DictationPreset.localPreset(id:in:)`. The
    /// menu title and the checkmark come from it.
    let current: DictationPreset

    var body: some View {
        SettingsRow(title: title, note: note) {
            Menu(current.name) {
                ForEach(presets) { preset in
                    Button {
                        if !preset.requiresAI { selection = preset.id }
                    } label: {
                        if preset.id == current.id {
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

    private func menuTitle(_ preset: DictationPreset) -> String {
        preset.requiresAI ? "\(preset.name) (needs AI)" : preset.name
    }
}
