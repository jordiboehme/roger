import AppKit
import SwiftUI

/// "Extra files" of a meeting: each with Reveal in Finder and Move to
/// Trash, plus Clean Up, which moves all of them to the Trash after a
/// confirmation. Never a permanent delete. Clean Up is offered only when
/// the meeting is not waiting for a retry. transcript.md is not changed.
struct LibraryExtraFilesSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    let item: LibraryItem
    @State private var files: [MeetingExtraFiles.File] = []
    @State private var confirmsCleanUp = false
    @State private var errorText: String?

    private var isLocked: Bool {
        !LibraryDocumentEditor.canEdit(item, activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder)
    }

    var body: some View {
        Group {
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Extra files")
                            .font(.headline)
                        Spacer()
                        if !item.isUnfinished {
                            Button("Clean Up…") { confirmsCleanUp = true }
                                .disabled(isLocked)
                        }
                    }
                    Text("A retry left these files in the meeting folder. Leftover audio can hold parts of the meeting that are not in the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(files, id: \.url) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.kind.isAudio ? "waveform" : "doc.text")
                                .foregroundStyle(.secondary)
                            Text(file.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Reveal in Finder")
                            Button {
                                trash([file.url])
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Move to Trash")
                            .disabled(isLocked)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .task(id: item) { refresh() }
        .confirmationDialog(
            files.count == 1 ? "Move 1 extra file to the Trash?" : "Move \(files.count) extra files to the Trash?",
            isPresented: $confirmsCleanUp,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trash(files.map(\.url)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put them back from the Trash.")
        }
        .alert("Roger could not do that", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func refresh() {
        files = item.kind == .meeting ? MeetingExtraFiles.find(in: item.folderURL) : []
    }

    private func trash(_ urls: [URL]) {
        let failed = LibraryActions.moveToTrash(urls)
        refresh()
        errorText = LibraryActions.trashFailureMessage(failed)
    }
}
