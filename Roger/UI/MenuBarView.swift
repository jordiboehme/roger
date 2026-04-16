import SwiftUI

struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            statusHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Alerts
            if case .error(let msg) = coordinator.appState.dictationState {
                alertBanner(msg, isRetryable: msg.contains("Model") || msg.contains("download")) {
                    coordinator.dismissError()
                    Task { await coordinator.setupModel() }
                } onDismiss: {
                    coordinator.dismissError()
                }
            }

            if !coordinator.hotkeyActive && coordinator.appState.dictationState == .idle {
                alertBanner("Hotkey not active — grant Accessibility in Settings", isRetryable: false, onRetry: {}, onDismiss: nil)
            }

            if coordinator.isSettingUpModel {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Last transcription
            if let text = coordinator.appState.lastTranscription {
                Text(text)
                    .font(.callout)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 10)

            // Controls
            VStack(spacing: 2) {
                controlRow(label: "Mode", detail: coordinator.appState.transcriptionMode.modelDescription) {
                    @Bindable var state = coordinator.appState
                    Picker("", selection: $state.transcriptionMode) {
                        ForEach(TranscriptionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                controlRow(label: "Preset") {
                    @Bindable var state = coordinator.appState
                    Picker("", selection: $state.activePresetID) {
                        ForEach(coordinator.appState.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.vertical, 6)

            Divider().padding(.horizontal, 10)

            // Actions
            VStack(spacing: 0) {
                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Settings…")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    dismissPopover()
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                })

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Quit Roger")
                            .font(.system(size: 13))
                        Spacer()
                        Text("over & out")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .task {
            coordinator.permissionManager.checkPermissions()
        }
        .onChange(of: coordinator.appState.transcriptionMode) { _, _ in
            Task { await coordinator.setupModel() }
        }
    }

    // MARK: - Components

    private var statusHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(coordinator.appState.statusText)
                    .font(.system(size: 13, weight: .semibold))
                if coordinator.transcriptionEngine.isReady {
                    Text("Model loaded")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    private func alertBanner(_ message: String, isRetryable: Bool, onRetry: @escaping () -> Void, onDismiss: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if isRetryable {
                Button("Retry") { onRetry() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func controlRow(label: String, detail: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func menuItem(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch coordinator.appState.dictationState {
        case .idle: .green
        case .listening: .red
        case .transcribing, .processing, .inserting: .orange
        case .error: .red
        }
    }

    private func dismissPopover() {
        if let panel = NSApp.keyWindow as? NSPanel {
            panel.close()
        }
    }
}
