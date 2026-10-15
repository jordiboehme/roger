import ApplicationServices
import SwiftUI

/// Settings > Permissions: one row per permission with its status, a fix
/// and a test.
struct PermissionsPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var micTestResult: SettingsTestResult?
    @State private var accessibilityTestResult: SettingsTestResult?
    @State private var hotkeyTestResult: SettingsTestResult?
    @State private var hotkeyTestActive = false
    @State private var systemAudioTestResult: SettingsTestResult?
    @State private var systemAudioTestRunning = false
    /// nil while hidutil is asked.
    @State private var capsLockActive: Bool?
    /// Result of "Keep at Login": the note text and whether it worked.
    @State private var keepAtLoginResult: (text: String, succeeded: Bool)?

    var body: some View {
        let pm = coordinator.permissionManager
        SettingsForm {
            Section {
                SettingsRow(
                    title: "Microphone",
                    note: micTestResult?.text ?? "Roger hears your voice to transcribe it.",
                    noteColor: SettingsTestResult.color(for: micTestResult)
                ) {
                    HStack {
                        grantedStatus(pm.microphoneAuthorized)
                        if pm.microphoneAuthorized {
                            Button("Test") { testMicrophone() }
                        } else {
                            Button("Grant Access") {
                                Task {
                                    _ = await pm.requestMicrophone()
                                    if pm.microphoneAuthorized {
                                        await coordinator.warmUpMicrophone()
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsRow(
                    title: "Accessibility",
                    note: accessibilityTestResult?.text ?? "Roger types your text at the cursor and sees the dictation key.",
                    noteColor: SettingsTestResult.color(for: accessibilityTestResult)
                ) {
                    HStack {
                        grantedStatus(pm.accessibilityAuthorized)
                        if !pm.accessibilityAuthorized {
                            Button("Open System Settings") { pm.openAccessibilitySettings() }
                        }
                        Button("Test") { testAccessibility() }
                    }
                }
                if !pm.accessibilityAuthorized {
                    SettingsRow(
                        title: "Still not allowed?",
                        note: "Debug builds change the signature. Remove old Roger entries, then ask again."
                    ) {
                        Button("Reset and Ask Again") { resetAccessibility() }
                    }
                }

                SettingsRow(
                    title: "System audio",
                    note: systemAudioTestResult?.text ?? "Roger records the other side of a meeting. macOS asks when you first record.",
                    noteColor: SettingsTestResult.color(for: systemAudioTestResult)
                ) {
                    HStack {
                        SettingsStatus(level: .unknown, text: "Not known")
                        Button("Open System Settings") { openAudioCapturePane() }
                        if systemAudioTestRunning {
                            ProgressView().controlSize(.small)
                        }
                        Button(systemAudioTestRunning ? "Testing…" : "Test") {
                            Task { await testSystemAudio() }
                        }
                        .disabled(systemAudioTestRunning)
                    }
                }
            } header: {
                Text("Access")
            }

            Section {
                SettingsRow(
                    title: "Hotkey listener",
                    note: hotkeyTestResult?.text ?? "Roger listens for F18. Press Test, then the key.",
                    noteColor: SettingsTestResult.color(for: hotkeyTestResult)
                ) {
                    HStack {
                        SettingsStatus(
                            level: coordinator.hotkeyActive ? .good : .bad,
                            text: coordinator.hotkeyActive ? "Active" : "Not active"
                        )
                        if !coordinator.hotkeyActive {
                            Button("Retry") { coordinator.startHotkey() }
                        }
                        if hotkeyTestActive {
                            ProgressView().controlSize(.small)
                        }
                        Button(hotkeyTestActive ? "Listening…" : "Test") { testHotkey() }
                            .disabled(hotkeyTestActive)
                    }
                }
                SettingsRow(
                    title: "Caps Lock",
                    note: keepAtLoginResult?.text
                        ?? "Makes Caps Lock send F18. Keep at Login sets it up again after every restart.",
                    noteColor: keepAtLoginResult.map { $0.succeeded ? .green : .red } ?? .secondary
                ) {
                    HStack {
                        SettingsStatus(
                            level: capsLockActive == true ? .good : (capsLockActive == false ? .bad : .unknown),
                            text: capsLockActive == true ? "Sends F18" : (capsLockActive == false ? "Not set up" : "Checking")
                        )
                        if capsLockActive != true {
                            Button("Turn On") {
                                HotkeyManager.remapCapsLockToF18()
                                Task { capsLockActive = await CapsLockRemap.isActiveNow() }
                            }
                        }
                        Button("Keep at Login") { keepAtLogin() }
                    }
                }
            } header: {
                Text("Dictation key")
            }
        }
        .onAppear { pm.checkPermissions() }
        .task { capsLockActive = await CapsLockRemap.isActiveNow() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            pm.checkPermissions()
        }
    }

    private func keepAtLogin() {
        do {
            try HotkeyManager.installRemapLaunchAgent()
            keepAtLoginResult = ("Caps Lock is set up again after every restart.", true)
        } catch {
            keepAtLoginResult = ("Roger could not set this up: \(error.localizedDescription)", false)
        }
    }

    private func grantedStatus(_ granted: Bool) -> some View {
        SettingsStatus(level: granted ? .good : .bad, text: granted ? "Allowed" : "Not allowed")
    }

    // MARK: - Actions

    /// Deep-links to System Settings > Privacy & Security > Audio. Falls back
    /// to the Privacy & Security root if the specific anchor is unknown to
    /// the current macOS build.
    private func openAudioCapturePane() {
        let anchors = [
            "com.apple.preference.security?Privacy_AudioCapture",
            "com.apple.preference.security?Privacy_Audio",
            "com.apple.preference.security"
        ]
        for anchor in anchors {
            if let url = URL(string: "x-apple.systempreferences:\(anchor)"),
               NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @MainActor
    private func testSystemAudio() async {
        systemAudioTestResult = nil
        systemAudioTestRunning = true
        defer { systemAudioTestRunning = false }

        let tap = SystemAudioTap()
        do {
            let stream = try tap.startStreaming()

            // Give the IOProc a beat to actually start delivering buffers,
            // then play a short system sound from a child process. The tap
            // excludes Roger's own PID so an in-process AVAudioPlayer would
            // be invisible by design. afplay's separate PID routes through
            // the global mix normally and IS captured.
            try? await Task.sleep(nanoseconds: 150_000_000)

            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.6", "/System/Library/Sounds/Funk.aiff"]
            try? player.run()

            // Wall-clock timeout. If the user denied audio-capture permission,
            // the tap returns successfully but yields no buffers. The only
            // way we learn that is by waiting and seeing nothing arrive.
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                tap.stop()
            }

            var sawAudio = false
            for await wrapper in stream {
                if let channel = wrapper.buffer.floatChannelData?[0] {
                    let frames = Int(wrapper.buffer.frameLength)
                    var peak: Float = 0
                    for i in 0 ..< frames {
                        let v = abs(channel[i])
                        if v > peak { peak = v }
                    }
                    // Threshold is well above mic-bleed but below any audible
                    // playback. Funk.aiff peaks at 0.5+ at volume 0.6.
                    if peak > 0.01 {
                        sawAudio = true
                        break
                    }
                }
            }
            timeout.cancel()
            tap.stop()
            if player.isRunning { player.terminate() }

            systemAudioTestResult = sawAudio
                ? .success("Works. Roger heard the test sound.")
                : .failure("Roger heard nothing. Allow it in System Settings > Privacy & Security > Audio.")
        } catch {
            tap.stop()
            systemAudioTestResult = .failure(error)
        }
    }

    private func testMicrophone() {
        micTestResult = nil
        let service = coordinator.audioCaptureService
        let inputUID = coordinator.appState.resolvedInputDeviceUID
        Task {
            do {
                let result = try await service.probeAfterWarmUp(inputUID: inputUID)
                if let samples = result.samples, !samples.isEmpty {
                    let peak = samples.map { abs($0) }.max() ?? 0
                    micTestResult = .success("Works. Loudest level \(String(format: "%.3f", peak)).")
                } else if result.health == .halStarved {
                    micTestResult = .failure("The audio system of macOS is stuck. \(SettingsStuckAudio.advice)")
                } else {
                    micTestResult = .failure("Roger got no sound from the microphone.")
                }
            } catch {
                micTestResult = .failure(error)
            }
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
            ? .success("Works. Roger can read the focused field.")
            : .failure("Roger cannot read the focused field (error \(result.rawValue)).")
    }

    private func testHotkey() {
        hotkeyTestResult = nil
        hotkeyTestActive = true

        let originalStart = coordinator.hotkeyManager.onRecordingStarted
        let originalStop = coordinator.hotkeyManager.onRecordingStopped

        coordinator.hotkeyManager.onRecordingStarted = { [self] _ in
            Task { @MainActor in
                hotkeyTestResult = .success("Works. Roger saw the key.")
                hotkeyTestActive = false
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
        coordinator.hotkeyManager.onRecordingStopped = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if hotkeyTestActive {
                hotkeyTestResult = .failure("No key press in 10 seconds.")
                hotkeyTestActive = false
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
    }
}
