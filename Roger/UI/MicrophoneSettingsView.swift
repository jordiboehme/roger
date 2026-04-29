import CoreAudio
import SwiftUI

struct MicrophoneSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var devices: [AudioDeviceLookup.InputDevice] = []
    @State private var systemDefaultName: String?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var state = coordinator.appState
        ScrollView {
            VStack(spacing: 16) {
                activeDeviceCard
                pickerCard(state: state)
            }
            .padding()
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    // MARK: - Active device

    private var activeDeviceCard: some View {
        card(icon: "waveform.and.mic", title: "Active Input") {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeDeviceName)
                        .font(.system(size: 13, weight: .medium))
                    Text(activeDeviceSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(testing ? "Testing…" : "Test") { runTest() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(testing || !coordinator.permissionManager.microphoneAuthorized)
                if !coordinator.permissionManager.microphoneAuthorized {
                    Text("Microphone access required")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let testResult {
                    Text(testResult)
                        .font(.caption2)
                        .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                        .lineLimit(1)
                }
            }
        }
    }

    private var activeDeviceName: String {
        if let uid = coordinator.appState.selectedInputDeviceUID,
           let match = devices.first(where: { $0.id == uid }) {
            return match.name
        }
        return systemDefaultName ?? "System Default"
    }

    private var activeDeviceSubtitle: String {
        if coordinator.appState.selectedInputDeviceUID == nil {
            return "Automatic — follows the macOS system setting"
        }
        if let uid = coordinator.appState.selectedInputDeviceUID,
           !devices.contains(where: { $0.id == uid }) {
            return "Configured device not currently connected"
        }
        return "Explicitly selected"
    }

    // MARK: - Picker

    private func pickerCard(state: AppState) -> some View {
        card(icon: "mic.fill", title: "Input Device") {
            VStack(alignment: .leading, spacing: 8) {
                row(
                    label: automaticRowLabel,
                    detail: systemDefaultName.map { "Currently: \($0)" },
                    isSelected: state.selectedInputDeviceUID == nil
                ) {
                    state.selectedInputDeviceUID = nil
                    Task { await coordinator.warmUpMicrophone() }
                }

                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        row(
                            label: device.name,
                            detail: nil,
                            isSelected: state.selectedInputDeviceUID == device.id
                        ) {
                            state.selectedInputDeviceUID = device.id
                            Task { await coordinator.warmUpMicrophone() }
                        }
                    }
                }

                if let uid = state.selectedInputDeviceUID,
                   !devices.contains(where: { $0.id == uid }) {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Saved device is not connected. Using system default until it returns.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var automaticRowLabel: String {
        "Automatic (System Default)"
    }

    private func row(label: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card chrome

    private func card<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
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

    // MARK: - Actions

    private func refresh() {
        devices = AudioDeviceLookup.availableInputs()
        systemDefaultName = AudioDeviceLookup.systemDefaultInputName
    }

    private func runTest() {
        testResult = nil
        testing = true
        let service = coordinator.audioCaptureService
        service.preferredInputUID = coordinator.appState.selectedInputDeviceUID
        let expectedDeviceName = activeDeviceName
        do {
            try service.startCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let samples = service.stopCapture()
                let actualDefault = AudioDeviceLookup.systemDefaultInputName ?? "unknown"
                if let samples, !samples.isEmpty {
                    let peak = samples.map { abs($0) }.max() ?? 0
                    testResult = "OK — peak \(String(format: "%.3f", peak))"
                } else {
                    let routingHint = expectedDeviceName != actualDefault
                        ? " (system default: \(actualDefault))"
                        : ""
                    testResult = "Failed — 0 samples from \(expectedDeviceName)\(routingHint). Check mic privacy settings or MDM audio policy."
                }
                testing = false
            }
        } catch {
            testResult = "Failed — \(error.localizedDescription)"
            testing = false
        }
    }
}
