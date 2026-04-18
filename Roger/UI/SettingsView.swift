import ApplicationServices
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, permissions, microphone, aiProvider, presets, model, about
}

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        @Bindable var state = coordinator.appState
        TabView(selection: $selectedTab) {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            PresetsSettingsView()
                .environment(coordinator)
                .tabItem { Label("Presets", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(SettingsTab.presets)

            PermissionsSettingsView()
                .environment(coordinator)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)

            MicrophoneSettingsView()
                .environment(coordinator)
                .tabItem { Label("Microphone", systemImage: "mic.fill") }
                .tag(SettingsTab.microphone)

            AIProviderSettingsView()
                .environment(coordinator)
                .tabItem { Label("AI Provider", systemImage: "sparkles") }
                .tag(SettingsTab.aiProvider)

            ModelSettingsView(
                engine: coordinator.transcriptionEngine,
                isSettingUp: coordinator.isSettingUpModel,
                onSetup: { Task { await coordinator.setupModel() } }
            )
                .tabItem { Label("Model", systemImage: "cpu") }
                .tag(SettingsTab.model)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, minHeight: 500, idealHeight: 580, maxHeight: .infinity)
        .onAppear { consumePendingTab() }
        .onChange(of: state.pendingSettingsTab) { _, _ in consumePendingTab() }
    }

    private func consumePendingTab() {
        guard let pending = coordinator.appState.pendingSettingsTab else { return }
        selectedTab = pending
        coordinator.appState.pendingSettingsTab = nil
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Transcription
                settingsCard(icon: "waveform", title: "Transcription") {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsRow("Mode") {
                            Picker("", selection: $state.transcriptionMode) {
                                ForEach(TranscriptionMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        settingsRow("Model") {
                            Text(state.transcriptionMode.modelDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Activation
                settingsCard(icon: "keyboard", title: "Activation") {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsRow("Mode") {
                            Picker("", selection: $state.activationMode) {
                                ForEach(ActivationMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        settingsRow("Min. duration") {
                            HStack(spacing: 4) {
                                TextField("", value: $state.minimumRecordingDuration, format: .number)
                                    .frame(width: 44)
                                    .textFieldStyle(.roundedBorder)
                                Text("sec")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        settingsRow("Max. duration") {
                            HStack(spacing: 4) {
                                TextField("", value: $state.maximumRecordingDuration, format: .number)
                                    .frame(width: 44)
                                    .textFieldStyle(.roundedBorder)
                                Text("sec")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Text insertion
                settingsCard(icon: "text.cursor", title: "Text Insertion") {
                    Toggle("Restore clipboard after paste fallback", isOn: $state.restoreClipboard)
                        .font(.system(size: 12))
                }

                // Startup
                settingsCard(icon: "power", title: "Startup") {
                    Toggle("Launch Roger at login", isOn: $state.launchAtLogin)
                        .font(.system(size: 12))
                }
            }
            .padding()
        }
        .onAppear { state.syncLaunchAtLogin() }
        .onChange(of: state.transcriptionMode) { _, _ in
            Task { await coordinator.setupModel() }
        }
        .onChange(of: state.activationMode) { _, newMode in
            coordinator.hotkeyManager.activationMode = newMode
        }
    }

    private func settingsCard(icon: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func settingsRow(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            trailing()
        }
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var micTestResult: String?
    @State private var accessibilityTestResult: String?
    @State private var hotkeyTestResult: String?
    @State private var hotkeyTestActive = false

    var body: some View {
        let pm = coordinator.permissionManager
        ScrollView {
            VStack(spacing: 16) {
                // Microphone
                permissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture your voice for transcription.",
                    granted: pm.microphoneAuthorized,
                    action: {
                        Task {
                            await pm.requestMicrophone()
                            if pm.microphoneAuthorized {
                                await coordinator.warmUpMicrophone()
                            }
                        }
                    },
                    actionLabel: "Grant Access",
                    testAction: pm.microphoneAuthorized ? { testMicrophone() } : nil,
                    testResult: micTestResult
                )

                // Accessibility
                permissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required to insert text at your cursor and detect the global hotkey.",
                    granted: pm.accessibilityAuthorized,
                    action: { pm.openAccessibilitySettings() },
                    actionLabel: "Open Settings",
                    testAction: { testAccessibility() },
                    testResult: accessibilityTestResult,
                    extraContent: !pm.accessibilityAuthorized ? AnyView(accessibilityHelp) : nil
                )

                // Hotkey
                hotkeyCard
            }
            .padding()
        }
        .onAppear { pm.checkPermissions() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            pm.checkPermissions()
        }
    }

    // MARK: - Card Components

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void,
        actionLabel: String,
        testAction: (() -> Void)? = nil,
        testResult: String? = nil,
        extraContent: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(granted ? .green : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(granted ? .green : .red)
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let extraContent {
                extraContent
            }

            HStack(spacing: 8) {
                if !granted {
                    Button(actionLabel, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if let testAction {
                    Button("Test", action: testAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if let testResult {
                    Text(testResult)
                        .font(.caption2)
                        .foregroundStyle(testResult.contains("OK") ? .green : .red)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var accessibilityHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug builds change code signature. Remove old \"Roger\" entries, then re-add.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Reset & Re-prompt") { resetAccessibility() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }

    private var hotkeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "capslock.fill")
                    .font(.title2)
                    .foregroundStyle(coordinator.hotkeyActive ? .green : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Hotkey").font(.headline)
                        Spacer()
                        Text(coordinator.hotkeyActive ? "Active" : "Not active")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(coordinator.hotkeyActive ? .green.opacity(0.15) : .red.opacity(0.15))
                            .foregroundStyle(coordinator.hotkeyActive ? .green : .red)
                            .clipShape(Capsule())
                    }
                    Text("Caps Lock remapped to push-to-talk via hidutil.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("Enable Remap") {
                    HotkeyManager.remapCapsLockToF18()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Persist for Login") {
                    try? HotkeyManager.installRemapLaunchAgent()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !coordinator.hotkeyActive {
                    Button("Retry Setup") { coordinator.startHotkey() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Button(hotkeyTestActive ? "Listening…" : "Test Hotkey") { testHotkey() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hotkeyTestActive)

                if hotkeyTestActive {
                    ProgressView().controlSize(.small)
                }

                if let result = hotkeyTestResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(result.contains("OK") ? .green : .red)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Actions

    private func testMicrophone() {
        micTestResult = nil
        let service = coordinator.audioCaptureService
        do {
            try service.startCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let samples = service.stopCapture()
                if let samples, !samples.isEmpty {
                    let peak = samples.map { abs($0) }.max() ?? 0
                    micTestResult = "OK — \(samples.count) samples (peak: \(String(format: "%.3f", peak)))"
                } else {
                    micTestResult = "Failed — no audio captured"
                }
            }
        } catch {
            micTestResult = "Failed — \(error.localizedDescription)"
        }
    }

    private func resetAccessibility() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "com.jordiboehme.roger"]
        try? task.run()
        task.waitUntilExit()
        coordinator.permissionManager.requestAccessibility()
    }

    private func testAccessibility() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        accessibilityTestResult = result == .success
            ? "OK — can read focused UI element"
            : "Failed — error \(result.rawValue)"
    }

    private func testHotkey() {
        hotkeyTestResult = nil
        hotkeyTestActive = true

        let originalStart = coordinator.hotkeyManager.onRecordingStarted
        let originalStop = coordinator.hotkeyManager.onRecordingStopped

        coordinator.hotkeyManager.onRecordingStarted = { [self] _ in
            Task { @MainActor in
                hotkeyTestResult = "OK — keypress detected!"
                hotkeyTestActive = false
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
        coordinator.hotkeyManager.onRecordingStopped = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if hotkeyTestActive {
                hotkeyTestResult = "Timeout — no keypress in 10s"
                hotkeyTestActive = false
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
    }
}

// MARK: - Model

struct ModelSettingsView: View {
    var engine: TranscriptionEngine
    var isSettingUp: Bool
    var onSetup: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status card
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text("Speech Model")
                            .font(.headline)
                        Spacer()

                        if isSettingUp {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Loading…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if engine.isReady {
                            Text("Ready")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        } else {
                            Text("Not loaded")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.red.opacity(0.15))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        }
                    }

                    Text("Roger uses WhisperKit for on-device speech recognition. Models run entirely on your Mac using the Neural Engine — your voice data never leaves your machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !engine.isReady && !isSettingUp {
                        Button("Download Model") { onSetup() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding()
        }
    }
}

// MARK: - About

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

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

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("Powered by")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Link("WhisperKit", destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!)
                        .font(.caption2)
                    Text("&")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Link("OpenAI Whisper", destination: URL(string: "https://github.com/openai/whisper")!)
                        .font(.caption2)
                }

                Text("Created with \u{2764}\u{FE0F} by Jordi Böhme  \u{00B7}  MIT License")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
