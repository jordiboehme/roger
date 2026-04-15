import SwiftUI

struct MenuBarView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(coordinator.appState.statusText)
                    .font(.headline)
                Spacer()
            }

            // Model download progress
            if let progress = coordinator.appState.modelDownloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading model…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                }
            }

            // Last transcription
            if let text = coordinator.appState.lastTranscription {
                GroupBox {
                    Text(text)
                        .font(.body)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

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

            Divider()

            // Actions
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit Roger") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding()
        .frame(width: 280)
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
