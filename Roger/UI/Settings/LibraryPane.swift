import AppKit
import SwiftUI

/// Settings > Library & Meetings: the library folder, older folders and
/// how meetings are recorded and transcribed.
struct LibraryPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showingFolderPicker = false

    var body: some View {
        @Bindable var state = coordinator.appState
        SettingsForm {
            Section {
                SettingsRow(
                    title: "Library folder",
                    note: state.libraryLayout.root.path + (state.libraryRoot == nil ? " (default)" : ""),
                    truncatesNote: true
                ) {
                    HStack {
                        Button("Choose…") { showingFolderPicker = true }
                        if state.libraryRoot != nil {
                            Button("Reset") {
                                state.libraryRoot = nil
                                // Part A Task 5: the default root is created here.
                                LibraryLayout.createRootIfDefault(state.libraryLayout)
                                coordinator.libraryChanges.reconcile()
                            }
                        }
                    }
                }
                HStack {
                    Button("Open Library") { coordinator.openLibrary() }
                    Button("Reveal in Finder") { revealLibraryFolder() }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Roger saves log entries, meetings and file transcripts here, in the folders Logs, Meetings and Transcripts, by year and month. Existing files stay where they are when you change the folder.")
            }

            if !state.extraScanFolders.isEmpty {
                Section {
                    ForEach(state.extraScanFolders, id: \.path) { folder in
                        SettingsRow(title: folder.lastPathComponent, note: folder.path, truncatesNote: true) {
                            Button("Forget") {
                                state.extraScanFolders.removeAll { $0 == folder }
                            }
                            .help("Stop looking for meetings in this folder. No files are deleted.")
                        }
                    }
                } header: {
                    Text("Older folders")
                } footer: {
                    Text("Roger still finds meetings in these folders. Forget stops that. No files are deleted.")
                }
            }

            Section("Meetings") {
                SettingsToggle(
                    title: "Keep audio",
                    note: "When off, Roger deletes mic.m4a and system.m4a once the transcript is written.",
                    isOn: $state.keepMeetingAudio
                )
                LocalPresetMenu(
                    title: "Preset",
                    note: "Cleans up the transcript on your Mac. Presets with AI steps cannot be picked.",
                    presets: state.presets,
                    selection: $state.meetingTranscriptionPresetID,
                    current: state.meetingTranscriptionPreset
                )
                SettingsToggle(
                    title: "Speaker labels for system audio",
                    note: state.meetingDiarizeSystem
                        ? "The other people show up as Other 1, Other 2 and so on."
                        : "Everything from system audio is labeled Other.",
                    isOn: $state.meetingDiarizeSystem
                )
                SettingsToggle(
                    title: "Speaker labels for the microphone",
                    note: "Turn this on when more than one person talks into your microphone. The main voice stays Me.",
                    isOn: $state.meetingDiarizeMic
                )
            }

            Section("Reliability") {
                SettingsRow(title: "New audio chunk every", note: "Long meetings are saved in chunks. A crash loses at most one chunk.") {
                    Stepper(value: $state.meetingMaxSegmentMinutes, in: 5 ... 60, step: 5) {
                        Text("\(state.meetingMaxSegmentMinutes) min")
                            .monospacedDigit()
                    }
                }
            }
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
        // Only the default folder is created; a missing custom one may be on
        // a drive that is not connected.
        guard LibraryLayout.createRootIfDefault(coordinator.appState.libraryLayout) else {
            let alert = NSAlert()
            alert.messageText = "Library folder not found"
            alert.informativeText = LibraryRootMissingError(path: folder.path).localizedDescription
            alert.runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
