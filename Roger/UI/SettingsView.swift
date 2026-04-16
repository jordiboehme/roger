import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = coordinator.appState
        TabView {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gear") }

            PermissionsSettingsView()
                .environment(coordinator)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            AIProviderSettingsView()
                .environment(coordinator)
                .tabItem { Label("AI Provider", systemImage: "sparkles") }

            PresetsSettingsView()
                .environment(coordinator)
                .tabItem { Label("Presets", systemImage: "antenna.radiowaves.left.and.right") }

            ModelSettingsView(
                engine: coordinator.transcriptionEngine,
                isSettingUp: coordinator.isSettingUpModel,
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
            Picker("Transcription Mode", selection: $state.transcriptionMode) {
                ForEach(TranscriptionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
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
                    action: { Task { await pm.requestMicrophone() } },
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

        coordinator.hotkeyManager.onRecordingStarted = { [self] in
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
        Form {
            LabeledContent("Status") {
                if isSettingUp {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(.caption)
                    }
                } else if engine.isReady {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Download Model") {
                        onSetup()
                    }
                }
            }

            Text("Roger uses WhisperKit for on-device speech recognition. The model runs entirely on your Mac using the Neural Engine.")
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
