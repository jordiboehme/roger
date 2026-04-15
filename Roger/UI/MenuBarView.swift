import SwiftUI

struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    var openSettings: () -> Void

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
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

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
                Text("Language")
                Spacer()
                @Bindable var state = coordinator.appState
                Picker("", selection: $state.selectedLanguage) {
                    ForEach(Language.allCases) { lang in
                        Text(lang.displayName).tag(lang)
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
            MenuBarButton(title: "Settings…") {
                openSettings()
            }

            MenuBarButton(title: "Quit Roger") {
                NSApp.terminate(nil)
            }

            Spacer()
                .frame(height: 6)
        }
        .frame(width: 260)
        .task {
            coordinator.permissionManager.checkPermissions()
            if !coordinator.transcriptionEngine.isReady {
                await coordinator.setupModel()
            }
            coordinator.hotkeyManager.start(mode: coordinator.appState.activationMode)
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
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}
