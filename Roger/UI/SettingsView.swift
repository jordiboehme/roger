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
        Form {
            // Microphone
            Section {
                LabeledContent("Microphone") {
                    HStack {
                        Image(systemName: pm.microphoneAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(pm.microphoneAuthorized ? .green : .red)
                        if !pm.microphoneAuthorized {
                            Button("Request") {
                                Task { await pm.requestMicrophone() }
                            }
                        }
                    }
                }

                if pm.microphoneAuthorized {
                    HStack {
                        Button("Test Microphone") { testMicrophone() }
                        if let result = micTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.contains("OK") ? .green : .red)
                        }
                    }
                }
            }

            // Accessibility
            Section {
                LabeledContent("Accessibility") {
                    HStack {
                        Image(systemName: pm.accessibilityAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(pm.accessibilityAuthorized ? .green : .red)
                        Button("Open Settings") {
                            pm.openAccessibilitySettings()
                        }
                    }
                }

                if !pm.accessibilityAuthorized {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Each new build changes the code signature. Remove all old \"Roger\" entries from Accessibility, then re-add the current one:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Bundle.main.bundlePath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Button("Reset Accessibility for Roger") {
                            resetAccessibility()
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Button("Test Accessibility") { testAccessibility() }
                    if let result = accessibilityTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("OK") ? .green : .red)
                    }
                }
            }

            // Caps Lock / Hotkey
            Section {
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

                HStack {
                    Button(hotkeyTestActive ? "Listening for keypress…" : "Test Hotkey") {
                        testHotkey()
                    }
                    .disabled(hotkeyTestActive)

                    if hotkeyTestActive {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let result = hotkeyTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.contains("OK") ? .green : .red)
                    }
                }

                LabeledContent("Hotkey Status") {
                    Text(coordinator.hotkeyActive ? "Active" : "Not active")
                        .foregroundStyle(coordinator.hotkeyActive ? .green : .red)
                }

                if !coordinator.hotkeyActive {
                    Button("Retry Hotkey Setup") {
                        coordinator.startHotkey()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pm.checkPermissions()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            pm.checkPermissions()
        }
    }

    // MARK: - Tests

    private func testMicrophone() {
        micTestResult = nil
        let service = coordinator.audioCaptureService
        do {
            try service.startCapture()
            // Record for 0.5s then stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let samples = service.stopCapture()
                if let samples, !samples.isEmpty {
                    let peak = samples.map { abs($0) }.max() ?? 0
                    micTestResult = "OK — captured \(samples.count) samples (peak: \(String(format: "%.3f", peak)))"
                } else {
                    micTestResult = "Failed — no audio captured"
                }
            }
        } catch {
            micTestResult = "Failed — \(error.localizedDescription)"
        }
    }

    private func resetAccessibility() {
        // Reset TCC accessibility entry for this app, then re-prompt
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "com.jordiboehme.roger"]
        try? task.run()
        task.waitUntilExit()

        // Re-prompt
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
        if result == .success {
            accessibilityTestResult = "OK — can read focused UI element"
        } else {
            accessibilityTestResult = "Failed — cannot access UI elements (error \(result.rawValue))"
        }
    }

    private func testHotkey() {
        hotkeyTestResult = nil
        hotkeyTestActive = true

        // Temporarily override callbacks to detect keypress
        let originalStart = coordinator.hotkeyManager.onRecordingStarted
        let originalStop = coordinator.hotkeyManager.onRecordingStopped

        coordinator.hotkeyManager.onRecordingStarted = { [self] in
            Task { @MainActor in
                hotkeyTestResult = "OK — hotkey press detected!"
                hotkeyTestActive = false
                // Restore original callbacks
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
        coordinator.hotkeyManager.onRecordingStopped = nil

        // Timeout after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if hotkeyTestActive {
                hotkeyTestResult = "Timeout — no keypress detected in 10s"
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
