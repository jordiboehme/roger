import SwiftUI

/// Settings > Files: where transcripts of dropped audio and video files go
/// and how they are processed.
struct FilesPane: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = coordinator.appState
        SettingsForm {
            Section {
                Picker(selection: $state.fileTranscriptOutputLocation) {
                    ForEach(FileTranscriptOutputLocation.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    SettingsLabel(
                        title: "Save to",
                        note: Self.outputNote(state.fileTranscriptOutputLocation, transcriptsFolder: state.libraryLayout.kindFolder(.transcripts)),
                        truncatesNote: state.fileTranscriptOutputLocation == .library
                    )
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Drop an audio or video file on the menu bar icon. Roger saves the transcript as a Markdown file. It never overwrites a file, it adds a number.")
            }

            Section {
                // A deleted or AI preset shows as Plain, the preset in use.
                LocalPresetMenu(
                    title: "Preset",
                    note: "Files are transcribed on your Mac. Presets with AI steps cannot be picked.",
                    presets: state.presets,
                    selection: $state.fileTranscriptionPresetID,
                    currentName: state.fileTranscriptionPreset.name
                )
                SettingsToggle(
                    title: "Speaker labels",
                    note: state.fileTranscriptionDiarize
                        ? "Adds [Speaker 0] and [Speaker 1] labels. The speaker models (about 150 MB) download the first time."
                        : "Adds a label for each speaker.",
                    isOn: $state.fileTranscriptionDiarize
                )
            } header: {
                Text("Processing")
            }
        }
    }

    /// The folder a transcript lands in.
    static func outputNote(_ location: FileTranscriptOutputLocation, transcriptsFolder: URL) -> String {
        switch location {
        case .library: return transcriptsFolder.path + "/YYYY/MM"
        case .alongsideSource: return "In the folder of the dropped file, as <file name>.md."
        }
    }
}
