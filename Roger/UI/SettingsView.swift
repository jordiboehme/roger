import ApplicationServices
import KeyboardShortcuts
import SwiftUI

// MARK: - File Transcription

struct FileTranscriptionSettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Output destination
                settingsCard(icon: "doc.text.magnifyingglass", title: "Output") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Drop an audio or video file on Roger's menu bar icon. The transcript is saved as a Markdown file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        settingsRow("Save to") {
                            Picker("", selection: $state.fileTranscriptOutputLocation) {
                                ForEach(FileTranscriptOutputLocation.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        if state.fileTranscriptOutputLocation == .library {
                            let transcriptsPath = state.libraryLayout.kindFolder(.transcripts).path + "/YYYY/MM"
                            Text(transcriptsPath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(transcriptsPath)
                        }

                        Text(filenameRuleText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Post-processing
                settingsCard(icon: "slider.horizontal.3", title: "Post-Processing") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("File transcription runs entirely on-device. Presets with AI steps are disabled. Pick one that only uses filler removal, dedup and your custom dictionary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        settingsRow("Preset") {
                            Menu {
                                ForEach(state.presets) { preset in
                                    Button {
                                        if !preset.requiresAI {
                                            state.fileTranscriptionPresetID = preset.id
                                        }
                                    } label: {
                                        HStack {
                                            if preset.id == state.fileTranscriptionPresetID {
                                                Image(systemName: "checkmark")
                                            }
                                            Text(preset.requiresAI ? "\(preset.name) (requires AI)" : preset.name)
                                        }
                                    }
                                    .disabled(preset.requiresAI)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(state.fileTranscriptionPreset.name)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }

                        settingsRow("Speaker labels") {
                            Toggle("", isOn: $state.fileTranscriptionDiarize)
                                .labelsHidden()
                        }
                        if state.fileTranscriptionDiarize {
                            Text("Adds [Speaker 0] / [Speaker 1] labels. Downloads ~150 MB of speaker models on first use.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var filenameRuleText: String {
        "Saved as <filename>.md. Existing files are never overwritten. Roger adds a number."
    }

    private func settingsCard(icon: String, title: String, @ViewBuilder content: () -> some View) -> some View {
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

    private func settingsRow(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            trailing()
        }
    }
}

// MARK: - Model

struct ModelSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showUninstallConfirm = false

    var body: some View {
        let isSettingUp = coordinator.isSettingUpModel
        let isModelReady = coordinator.isModelReady

        ScrollView {
            VStack(spacing: 16) {
                settingsCard(icon: "waveform", title: "Transcription") {
                    settingsRow("Model") {
                        Text(TranscriptionEngine.modelName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Speech Model
                settingsCard(icon: "cpu", title: "Speech Model") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Text("Roger uses Parakeet (via FluidAudio) for on-device speech recognition. Models run entirely on your Mac using the Neural Engine. Your voice data never leaves your machine.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isSettingUp {
                                VStack(alignment: .trailing, spacing: 4) {
                                    if let progress = coordinator.modelSetupProgress {
                                        ProgressView(value: progress.fraction)
                                            .frame(width: 140)
                                        Text(progress.stage)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        HStack(spacing: 6) {
                                            ProgressView().controlSize(.small)
                                            Text("Loading…")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } else if isModelReady {
                                Text("Ready")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.green.opacity(0.15))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            } else {
                                Text("Not loaded")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                        }

                        if let err = coordinator.lastModelError {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !isSettingUp {
                            if isModelReady {
                                HStack(spacing: 8) {
                                    Spacer()

                                    Button("Uninstall", role: .destructive) {
                                        showUninstallConfirm = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            } else {
                                Button("Download Model") {
                                    Task { await coordinator.setupModel() }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .confirmationDialog(
            "Uninstall Speech Model?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await coordinator.uninstallModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model will be deleted from your Mac. You can re-download it at any time.")
        }
    }

    private func settingsCard(icon: String, title: String, @ViewBuilder content: () -> some View) -> some View {
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

    private func settingsRow(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            trailing()
        }
    }
}

// MARK: - About

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

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

            VStack(spacing: 10) {
                Text("Powered by [FluidAudio](https://github.com/FluidInference/FluidAudio), [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) & [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .tint(.accentColor)

                Text("Created with \u{2764}\u{FE0F} by Jordi Böhme  \u{00B7}  MIT License")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
