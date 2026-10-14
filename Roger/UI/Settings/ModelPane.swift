import SwiftUI

/// Settings > Speech Model: the speech model, its status, Download and Remove.
struct ModelPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var confirmRemove = false

    var body: some View {
        let isSettingUp = coordinator.isSettingUpModel
        let isReady = coordinator.isModelReady
        SettingsForm {
            Section {
                SettingsRow(title: "Model", note: "Runs on your Mac with the Neural Engine. Your voice never leaves your Mac.") {
                    Text(TranscriptionEngine.modelName)
                        .foregroundStyle(.secondary)
                }
                SettingsRow(
                    title: "Status",
                    note: coordinator.lastModelError,
                    noteColor: .red
                ) {
                    HStack {
                        if isSettingUp {
                            if let progress = coordinator.modelSetupProgress {
                                ProgressView(value: progress.fraction)
                                    .frame(minWidth: 60, maxWidth: 140)
                                Text(progress.stage)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                                Text("Loading…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if isReady {
                            SettingsStatus(level: .good, text: "Downloaded")
                            Button("Remove…", role: .destructive) { confirmRemove = true }
                        } else if coordinator.lastModelError != nil {
                            // The error shows as the note under Status.
                            SettingsStatus(level: .bad, text: "Not loaded")
                            Button("Try Again") {
                                Task { await coordinator.setupModel() }
                            }
                        } else {
                            SettingsStatus(level: .bad, text: "Not downloaded")
                            Button("Download") {
                                Task { await coordinator.setupModel() }
                            }
                        }
                    }
                }
            } header: {
                Text("Speech model")
            }
        }
        .confirmationDialog("Remove the speech model?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await coordinator.uninstallModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roger deletes the model from your Mac. You can download it again at any time.")
        }
    }
}
