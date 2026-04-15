import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = coordinator.appState
        TabView {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gear") }

            PermissionsSettingsView(permissionManager: coordinator.permissionManager)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            AIProviderSettingsView()
                .environment(coordinator)
                .tabItem { Label("AI Provider", systemImage: "sparkles") }

            PresetsSettingsView()
                .environment(coordinator)
                .tabItem { Label("Presets", systemImage: "antenna.radiowaves.left.and.right") }

            ModelSettingsView(
                engine: coordinator.transcriptionEngine,
                downloadProgress: coordinator.appState.modelDownloadProgress,
                onSetup: { Task { await coordinator.setupModel() } }
            )
                .tabItem { Label("Model", systemImage: "cpu") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Picker("Language", selection: $state.selectedLanguage) {
                ForEach(Language.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Picker("Activation Mode", selection: $state.activationMode) {
                ForEach(ActivationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Toggle("Restore clipboard after paste", isOn: $state.restoreClipboard)

            HStack {
                Text("Minimum recording duration")
                Spacer()
                TextField("", value: $state.minimumRecordingDuration, format: .number)
                    .frame(width: 50)
                    .textFieldStyle(.roundedBorder)
                Text("seconds")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    var permissionManager: PermissionManager

    var body: some View {
        Form {
            LabeledContent("Microphone") {
                HStack {
                    Image(systemName: permissionManager.microphoneAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(permissionManager.microphoneAuthorized ? .green : .red)
                    if !permissionManager.microphoneAuthorized {
                        Button("Request") {
                            Task { await permissionManager.requestMicrophone() }
                        }
                    }
                }
            }

            LabeledContent("Accessibility") {
                HStack {
                    Image(systemName: permissionManager.accessibilityAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(permissionManager.accessibilityAuthorized ? .green : .red)
                    if !permissionManager.accessibilityAuthorized {
                        Button("Open Settings") {
                            permissionManager.requestAccessibility()
                        }
                    }
                }
            }

            LabeledContent("Caps Lock Remap") {
                HStack {
                    Button("Enable") {
                        HotkeyManager.remapCapsLockToF18()
                    }
                    Button("Install for Login") {
                        try? HotkeyManager.installRemapLaunchAgent()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissionManager.checkPermissions()
        }
    }
}

// MARK: - Model

struct ModelSettingsView: View {
    var engine: TranscriptionEngine
    var downloadProgress: Double?
    var onSetup: () -> Void

    var body: some View {
        Form {
            LabeledContent("Status") {
                if let progress = downloadProgress {
                    ProgressView(value: progress)
                        .frame(width: 120)
                } else if engine.isReady {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Download Model") {
                        onSetup()
                    }
                }
            }

            Text("Roger uses WhisperKit for on-device speech recognition. The model (~500 MB) runs entirely on your Mac using the Neural Engine.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            VStack(spacing: 4) {
                Text("Roger")
                    .font(.title.weight(.semibold))
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Speech-to-Text for macOS")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link(destination: URL(string: "https://ko-fi.com/V7V31T6CL9")!) {
                    Label("Support Me", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.regular)

                Link(destination: URL(string: "https://github.com/jordiboehme/roger")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()

            VStack(spacing: 6) {
                Text("Created with \u{2764}\u{FE0F} by Jordi Böhme")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\u{00A9} 2026 Jordi Böhme. MIT License.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
