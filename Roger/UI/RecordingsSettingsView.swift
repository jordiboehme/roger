import AppKit
import KeyboardShortcuts
import SwiftUI

/// Settings tab for meeting recording and the library folder: where files
/// go, extra folders, Keep audio, hotkey, speakers, cleanup and chunk length.
/// Browsing past recordings happens in the library window.
struct RecordingsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showingFolderPicker = false

    var body: some View {
        @Bindable var state = coordinator.appState
        ScrollView {
            VStack(spacing: 16) {
                // Library folder
                settingsCard(icon: "folder", title: "Library Folder") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Roger saves log entries, meetings and file transcripts here, in the folders Logs, Meetings and Transcripts, sorted by year and month.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            Text(state.libraryLayout.root.path)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            if state.libraryRoot == nil {
                                Text("Default")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.secondary.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose…") { showingFolderPicker = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            if state.libraryRoot != nil {
                                Button("Reset") {
                                    state.libraryRoot = nil
                                    coordinator.libraryChanges.reconcile()
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Open Library") { coordinator.openLibrary() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            Button("Reveal in Finder") { revealLibraryFolder() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            Spacer()
                            Text("Existing files stay where they are when the folder changes.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        HStack {
                            Text("Keep audio after transcription")
                                .font(.system(size: 12))
                            Spacer()
                            Toggle("", isOn: $state.keepMeetingAudio)
                                .labelsHidden()
                        }
                        Text("When off, mic.m4a and system.m4a are deleted once the meeting transcript is written.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if !state.extraScanFolders.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Older folders")
                                    .font(.system(size: 12, weight: .medium))
                                ForEach(state.extraScanFolders, id: \.path) { folder in
                                    HStack(spacing: 8) {
                                        Text(folder.path)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Button("Forget") {
                                            state.extraScanFolders.removeAll { $0 == folder }
                                        }
                                        .help("Stop looking for meetings in this folder. No files are deleted.")
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                Text("Roger still finds meetings in these folders.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Hotkey + diarization
                settingsCard(icon: "keyboard", title: "Hotkey & Speakers") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Toggle recording")
                                .font(.system(size: 12))
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .meetingRecordingToggle)
                                .shortcutValidation { shortcut in
                                    if shortcut.key == .f18 {
                                        return .disallow(reason: "F18 is Roger's dictation hotkey (Caps Lock).")
                                    }
                                    return .allow
                                }
                        }
                        Text("Optional. Set a global shortcut to start and stop a recording without opening the menu bar.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Identify remote speakers")
                                .font(.system(size: 12))
                            Spacer()
                            Toggle("", isOn: $state.meetingDiarizeSystem)
                                .labelsHidden()
                        }
                        Text(state.meetingDiarizeSystem
                             ? "Diarizes the system track to label remote participants as Other 1, Other 2…"
                             : "Every paragraph from the system track will be labelled simply as Other.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Identify mic-side speakers")
                                .font(.system(size: 12))
                            Spacer()
                            Toggle("", isOn: $state.meetingDiarizeMic)
                                .labelsHidden()
                        }
                        Text("Off by default. Enable when more than one person speaks into your microphone (e.g., people sharing a laptop). The dominant voice stays Me; additional speakers join the Other N pool.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Transcription post-processing
                settingsCard(icon: "slider.horizontal.3", title: "Transcription") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cleanup runs locally on the merged transcript: filler-word removal, dedup and your custom dictionary. Presets with AI steps are disabled. Meeting transcripts always stay on-device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Preset")
                                .font(.system(size: 12))
                            Spacer()
                            Menu {
                                ForEach(state.presets) { preset in
                                    Button {
                                        if !preset.requiresAI {
                                            state.meetingTranscriptionPresetID = preset.id
                                        }
                                    } label: {
                                        HStack {
                                            if preset.id == state.meetingTranscriptionPresetID {
                                                Image(systemName: "checkmark")
                                            }
                                            Text(preset.requiresAI ? "\(preset.name) (requires AI)" : preset.name)
                                        }
                                    }
                                    .disabled(preset.requiresAI)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(state.meetingTranscriptionPreset.name)
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
                    }
                }

                // Reliability
                settingsCard(icon: "clock.arrow.circlepath", title: "Reliability") {
                    HStack {
                        Text("Roll audio chunk every")
                            .font(.system(size: 12))
                        Spacer()
                        Stepper(
                            value: $state.meetingMaxSegmentMinutes,
                            in: 5 ... 60,
                            step: 5
                        ) {
                            Text("\(state.meetingMaxSegmentMinutes) min")
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.libraryRoot = url
                coordinator.libraryChanges.reconcile()
            }
        }
    }

    private func revealLibraryFolder() {
        let folder = coordinator.appState.libraryLayout.root
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
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
}
