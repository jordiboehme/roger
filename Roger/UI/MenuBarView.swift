import SwiftUI

struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.appState.statusText)
                    .font(.headline)
                Spacer()

                // Error dismiss button
                if case .error = coordinator.appState.dictationState {
                    Button(action: { coordinator.dismissError() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Error retry
            if case .error(let msg) = coordinator.appState.dictationState {
                if msg.contains("Model") || msg.contains("download") {
                    MenuBarButton(title: "Retry Model Download") {
                        coordinator.dismissError()
                        Task { await coordinator.setupModel() }
                    }
                }
            }

            // Hotkey status warning
            if !coordinator.hotkeyActive && coordinator.appState.dictationState == .idle {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Hotkey not active — grant Accessibility permission")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // Model download progress
            if let progress = coordinator.appState.modelDownloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // Last transcription
            if let text = coordinator.appState.lastTranscription {
                Text(text)
                    .font(.callout)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()
                .padding(.vertical, 4)

            // Language picker
            HStack {
                Text("Mode")
                Spacer()
                @Bindable var state = coordinator.appState
                Picker("", selection: $state.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            // Preset picker
            HStack {
                Text("Preset")
                Spacer()
                @Bindable var state2 = coordinator.appState
                Picker("", selection: $state2.activePresetID) {
                    ForEach(coordinator.appState.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            Divider()
                .padding(.vertical, 4)

            // Actions
            SettingsLink {
                Text("Settings…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            })

            MenuBarButton(title: "Quit Roger") {
                NSApp.terminate(nil)
            }

            Spacer()
                .frame(height: 6)
        }
        .frame(width: 260)
        .task {
            coordinator.permissionManager.checkPermissions()
        }
    }

    private var statusColor: Color {
        switch coordinator.appState.dictationState {
        case .idle:
            return .green
        case .listening:
            return .red
        case .transcribing, .processing, .inserting:
            return .orange
        case .error:
            return .red
        }
    }
}

struct MenuBarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}
