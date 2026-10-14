import KeyboardShortcuts
import SwiftUI

/// Settings > General: how dictation starts and stops, the shortcuts, text
/// insertion and startup.
struct GeneralPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SettingsNavigation.self) private var navigation
    /// nil while hidutil is asked.
    @State private var capsLockActive: Bool?

    var body: some View {
        @Bindable var state = coordinator.appState
        let permissions = coordinator.permissionManager
        SettingsForm {
            if let message = Self.missingPermissionsMessage(
                microphone: permissions.microphoneAuthorized,
                accessibility: permissions.accessibilityAuthorized
            ) {
                Section {
                    SettingsBanner(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        message: message,
                        actionTitle: "Open Permissions"
                    ) {
                        navigation.selection = .permissions
                    }
                }
            }

            Section("Activation") {
                SettingsRow(title: "Mode", note: state.activationMode.note) {
                    Picker("Mode", selection: $state.activationMode) {
                        ForEach(ActivationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Minimum recording", note: "Shorter recordings are ignored, so a quick tap types nothing.") {
                    SettingsDurationStepper(seconds: $state.minimumRecordingDuration, range: 0 ... 10, step: 0.5)
                }
                SettingsRow(title: "Maximum recording", note: "Roger stops listening after this time.") {
                    SettingsDurationStepper(seconds: $state.maximumRecordingDuration, range: 30 ... 600, step: 30)
                }
            }

            Section("Shortcuts") {
                SettingsRow(title: "Dictation", note: Self.dictationNote(capsLockActive: capsLockActive)) {
                    HStack {
                        Text(Self.dictationKey(capsLockActive: capsLockActive))
                            .foregroundStyle(.secondary)
                        if capsLockActive == false {
                            Button("Set Up Caps Lock") { navigation.selection = .permissions }
                        }
                    }
                }
                SettingsRow(title: "Record a meeting", note: "Starts and stops a meeting recording.") {
                    SettingsShortcutRecorder(name: .meetingRecordingToggle)
                }
                SettingsRow(title: "Open the library") {
                    SettingsShortcutRecorder(name: .openLibrary)
                }
            }

            Section("Text insertion") {
                SettingsToggle(
                    title: "Restore the clipboard",
                    note: "When Roger has to paste the text, it puts your clipboard back afterwards.",
                    isOn: $state.restoreClipboard
                )
            }

            Section("Startup") {
                SettingsToggle(title: "Launch at login", isOn: $state.launchAtLogin)
            }
        }
        .onAppear {
            state.syncLaunchAtLogin()
            permissions.checkPermissions()
        }
        .task { capsLockActive = await CapsLockRemap.isActiveNow() }
        // Hides the banner soon after access is granted in System Settings.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            permissions.checkPermissions()
        }
        .onChange(of: state.activationMode) { _, newMode in
            coordinator.hotkeyManager.activationMode = newMode
        }
    }

    /// Banner text when Roger misses a permission it needs, nil otherwise.
    static func missingPermissionsMessage(microphone: Bool, accessibility: Bool) -> String? {
        switch (microphone, accessibility) {
        case (true, true): return nil
        case (false, false): return "Roger needs access to the microphone and to Accessibility."
        case (false, true): return "Roger needs access to the microphone to hear you."
        case (true, false): return "Roger needs Accessibility access to type your text and to see the dictation key."
        }
    }

    static func dictationKey(capsLockActive: Bool?) -> String {
        switch capsLockActive {
        case true?: return "Caps Lock"
        case false?: return "F18"
        case nil: return "Caps Lock or F18"
        }
    }

    static func dictationNote(capsLockActive: Bool?) -> String {
        switch capsLockActive {
        case true?: return "Caps Lock sends F18, Roger's dictation key."
        case false?: return "Caps Lock is not set up. Press F18 or set up Caps Lock."
        case nil: return "Roger listens for F18. Caps Lock sends F18 once it is set up."
        }
    }
}
