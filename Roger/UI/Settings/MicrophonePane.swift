import CoreAudio
import SwiftUI

/// Settings > Microphone: which input Roger records from, and a level test.
struct MicrophonePane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var devices: [AudioDeviceLookup.InputDevice] = []
    @State private var systemDefaultName: String?
    @State private var systemDefaultTransport: String?
    @State private var testResult: String?
    @State private var testing = false
    /// Peak of the last test, 0...1. The meter shows it.
    @State private var peak: Float = 0
    /// True when the last test hit the CoreAudio wedge (engine ran, zero
    /// buffers). Shows the Relaunch row.
    @State private var starved = false

    var body: some View {
        @Bindable var state = coordinator.appState
        let micAllowed = coordinator.permissionManager.microphoneAuthorized
        SettingsForm {
            Section("Input device") {
                Picker(selection: deviceSelection) {
                    Text("Automatic (System Default)").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                    if let uid = state.selectedInputDeviceUID, !devices.contains(where: { $0.id == uid }) {
                        Text("Saved device (not connected)").tag(Optional(uid))
                    }
                } label: {
                    SettingsLabel(title: "Microphone", note: deviceNote)
                }
            }

            Section {
                SettingsRow(
                    title: "Level",
                    note: micAllowed ? (testResult ?? "Speak and press Test.") : "Roger needs access to the microphone. See Permissions.",
                    noteColor: micAllowed ? SettingsResultColor.color(for: testResult) : .secondary
                ) {
                    HStack {
                        ProgressView(value: Double(min(max(peak, 0), 1)))
                            .frame(minWidth: 60, maxWidth: 140)
                        Button(testing ? "Testing…" : "Test") { runTest() }
                            .disabled(testing || !micAllowed)
                    }
                }
                if starved {
                    SettingsRow(title: "The audio system is stuck", note: AudioCaptureService.halStarvedAdvice) {
                        // Goes through the relaunch gate: unsaved edits are asked about first.
                        Button("Relaunch Roger") { coordinator.relaunchApp() }
                    }
                }
            } header: {
                Text("Test")
            } footer: {
                Text("The meter shows the loudest moment of the last test. Roger only uses the microphone while it records or tests.")
            }
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private var deviceSelection: Binding<String?> {
        Binding(
            get: { coordinator.appState.selectedInputDeviceUID },
            set: { uid in
                coordinator.appState.selectedInputDeviceUID = uid
                Task { await coordinator.warmUpMicrophone() }
            }
        )
    }

    private var deviceNote: String {
        let uid = coordinator.appState.selectedInputDeviceUID
        let device = uid.flatMap { uid in devices.first { $0.id == uid } }
        return Self.deviceNote(
            isAutomatic: uid == nil,
            deviceName: device?.name ?? systemDefaultName,
            transport: device.flatMap { AudioDeviceLookup.transportName(of: $0.deviceID) } ?? (uid == nil ? systemDefaultTransport : nil),
            isConnected: uid == nil || device != nil
        )
    }

    /// The note under the device menu: what Roger records from right now.
    static func deviceNote(isAutomatic: Bool, deviceName: String?, transport: String?, isConnected: Bool) -> String {
        guard isConnected else {
            return "The saved device is not connected. Roger uses the system default until it is back."
        }
        let name = deviceName ?? "No input device"
        let described = transport.map { "\(name), \($0)" } ?? name
        return isAutomatic ? "Now: \(described). Follows the macOS setting." : described
    }

    // MARK: - Actions

    private func refresh() {
        devices = AudioDeviceLookup.availableInputs()
        systemDefaultName = AudioDeviceLookup.systemDefaultInputName
        systemDefaultTransport = AudioDeviceLookup.systemDefaultInputID.flatMap(AudioDeviceLookup.transportName(of:))
    }

    private func runTest() {
        testResult = nil
        testing = true
        starved = false
        peak = 0
        let service = coordinator.audioCaptureService
        service.preferredInputUID = coordinator.appState.selectedInputDeviceUID
        let expectedDeviceName = devices.first { $0.id == coordinator.appState.selectedInputDeviceUID }?.name
            ?? systemDefaultName ?? "System Default"
        Task {
            do {
                let result = try await service.probe()
                let actualDefault = AudioDeviceLookup.systemDefaultInputName ?? "unknown"
                if let samples = result.samples, !samples.isEmpty {
                    peak = samples.map { abs($0) }.max() ?? 0
                    testResult = "OK: peak \(String(format: "%.3f", peak))"
                } else if result.health == .halStarved {
                    starved = true
                    testResult = "Failed - audio system is stuck"
                } else {
                    let routingHint = expectedDeviceName != actualDefault
                        ? " (system default: \(actualDefault))"
                        : ""
                    testResult = "Failed: 0 samples from \(expectedDeviceName)\(routingHint). Check mic privacy settings or MDM audio policy."
                }
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
