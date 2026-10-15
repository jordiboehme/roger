import CoreAudio
import SwiftUI

/// Settings > Microphone: which microphones Roger records from, and a level test.
struct MicrophonePane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var devices: [AudioDeviceLookup.InputDevice] = []
    @State private var systemDefaultName: String?
    /// UIDs of the connected inputs. Asked in refresh(), never in body:
    /// Core Audio can hang when coreaudiod is stuck.
    @State private var connected: Set<String> = []
    @State private var testResult: SettingsTestResult?
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
            Section {
                ForEach(Array(state.inputPriority.enumerated()), id: \.element.id) { index, choice in
                    SettingsRow(title: label(for: choice), note: note(for: choice)) {
                        HStack(spacing: 4) {
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .accessibilityLabel("Move up")
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == state.inputPriority.count - 1)
                                .accessibilityLabel("Move down")
                            if choice != .systemDefault {
                                Button { remove(index) } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add microphone…") {
                    ForEach(devicesNotInList) { device in
                        Button(device.name) { add(device) }
                    }
                }
                .disabled(devicesNotInList.isEmpty)
            } header: {
                Text("Microphones")
            } footer: {
                Text("Roger uses the first microphone in this list that is connected. Now: \(resolvedName).")
            }

            Section {
                SettingsRow(
                    title: "Level",
                    note: micAllowed ? (testResult?.text ?? "Speak and press Test.") : "Roger needs access to the microphone. See Permissions.",
                    noteColor: micAllowed ? SettingsTestResult.color(for: testResult) : .secondary
                ) {
                    HStack {
                        ProgressView(value: Double(min(max(peak, 0), 1)))
                            .frame(minWidth: 60, maxWidth: 140)
                        Button(testing ? "Testing…" : "Test") { runTest() }
                            .disabled(testing || !micAllowed)
                    }
                }
                if starved {
                    SettingsRow(title: "The audio system is stuck", note: SettingsStuckAudio.advice) {
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
        .onChange(of: coordinator.inputDevicesGeneration) { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private var devicesNotInList: [AudioDeviceLookup.InputDevice] {
        let listed = Set(coordinator.appState.inputPriority.map(\.id))
        return devices.filter { !listed.contains($0.id) }
    }

    private func label(for choice: InputChoice) -> String {
        switch choice {
        case .systemDefault: return "System default"
        case .device(let uid, let name): return devices.first { $0.id == uid }?.name ?? name
        }
    }

    private func note(for choice: InputChoice) -> String {
        switch choice {
        case .systemDefault: return "Now: \(systemDefaultName ?? "none")"
        case .device(let uid, _): return connected.contains(uid) ? "Connected" : "Not connected"
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = coordinator.appState.inputPriority
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        changed(list)
    }

    private func remove(_ index: Int) {
        var list = coordinator.appState.inputPriority
        guard list.indices.contains(index), list[index] != .systemDefault else { return }
        list.remove(at: index)
        changed(list)
    }

    private func add(_ device: AudioDeviceLookup.InputDevice) {
        var list = coordinator.appState.inputPriority
        let entry = InputChoice.device(uid: device.id, name: device.name)
        // Above System default, which stays last unless the user moved it.
        list.insert(entry, at: list.firstIndex(of: .systemDefault) ?? list.endIndex)
        changed(InputChoice.repaired(list))
    }

    private func changed(_ list: [InputChoice]) {
        coordinator.appState.inputPriority = list
        refresh()
        Task { await coordinator.warmUpMicrophone() }
    }

    /// Name of the microphone Roger records from right now.
    private var resolvedName: String {
        let uid = InputChoice.resolve(coordinator.appState.inputPriority, connectedUIDs: connected)
        let name = uid.flatMap { uid in devices.first { $0.id == uid }?.name }
        return name ?? systemDefaultName ?? "no input device"
    }

    // MARK: - Actions

    private func refresh() {
        devices = AudioDeviceLookup.availableInputs()
        connected = Set(devices.map(\.id))
        systemDefaultName = AudioDeviceLookup.systemDefaultInputName
        // A renamed device keeps its fresh name in the saved list.
        let list = coordinator.appState.inputPriority
        let renamed = list.map { choice -> InputChoice in
            if case .device(let uid, let name) = choice,
               let fresh = devices.first(where: { $0.id == uid })?.name, fresh != name {
                return .device(uid: uid, name: fresh)
            }
            return choice
        }
        if renamed != list { coordinator.appState.inputPriority = renamed }
    }

    private func runTest() {
        testResult = nil
        testing = true
        starved = false
        peak = 0
        let service = coordinator.audioCaptureService
        let inputUID = coordinator.appState.resolvedInputDeviceUID
        let expectedDeviceName = resolvedName
        Task {
            do {
                let result = try await service.probeAfterWarmUp(inputUID: inputUID)
                let actualDefault = AudioDeviceLookup.systemDefaultInputName ?? "unknown"
                if let samples = result.samples, !samples.isEmpty {
                    peak = samples.map { abs($0) }.max() ?? 0
                    testResult = .success("Works. Loudest level \(String(format: "%.3f", peak)).")
                } else if result.health == .halStarved {
                    starved = true
                    testResult = .failure("The audio system of macOS is stuck. See below.")
                } else {
                    let routingHint = expectedDeviceName != actualDefault
                        ? " The macOS default is \(actualDefault)."
                        : ""
                    testResult = .failure("Roger got no sound from \(expectedDeviceName).\(routingHint) Check the microphone access in Permissions.")
                }
            } catch {
                testResult = .failure(error)
            }
            testing = false
        }
    }
}
