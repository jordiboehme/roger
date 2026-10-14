import AppKit
import SwiftUI

/// "Extra files" of a meeting: each with Reveal in Finder and Move to
/// Trash, plus Clean Up, which moves all of them to the Trash after a
/// confirmation. Never a permanent delete. Clean Up is offered only when
/// the meeting is not waiting for a retry. transcript.md is not changed.
struct LibraryExtraFilesSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    let item: LibraryItem
    /// Its `sessionFolderChangeCount` for this folder lists the folder
    /// again. Only this section reads it, not the detail body.
    let model: LibraryModel
    @State private var files: [MeetingExtraFiles.File] = []
    @State private var confirmsCleanUp = false
    /// What Clean Up asks about, taken when the button is clicked, so the
    /// count in the question and the files moved are the same.
    @State private var cleanUpURLs: [URL] = []
    @State private var errorText: String?

    private var isLocked: Bool {
        !LibraryDocumentEditor.canEdit(item, activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder)
    }

    /// Checked again from disk right before anything moves: a retry may
    /// have started or failed since the section was drawn.
    private var mayTrash: Bool {
        !isLocked && !item.isUnfinished && !MeetingSessionScanner.isUnfinished(item.folderURL)
    }

    /// What Clean Up and the Trash buttons may move (never a folder).
    private var trashable: [MeetingExtraFiles.File] { files.filter(\.kind.isTrashable) }

    var body: some View {
        // A container that always exists, so `.task` runs and the dialogs
        // have a host even while there are no files.
        VStack(spacing: 0) {
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Extra files")
                            .font(.headline)
                        Spacer()
                        if !item.isUnfinished, !trashable.isEmpty {
                            Button("Clean Up…") {
                                cleanUpURLs = trashable.map(\.url)
                                confirmsCleanUp = true
                            }
                                .disabled(isLocked)
                        }
                    }
                    if !trashable.isEmpty {
                        Text("A retry left these files in the meeting folder. Leftover audio can hold parts of the meeting that are not in the transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if files.contains(where: { $0.kind == .subfolder }) {
                        Text("Roger does not write folders here and never moves them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files, id: \.url) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.kind == .subfolder ? "folder" : (file.kind.isAudio ? "waveform" : "doc.text"))
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
                            if file.kind.isTrashable {
                                Button {
                                    trash([file.url])
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Move to Trash")
                                .disabled(isLocked || item.isUnfinished)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .task(id: item) { refresh() }
        .onChange(of: model.sessionFolderChangeCount(for: item.folderURL)) { _, _ in refresh() }
        .confirmationDialog(
            cleanUpURLs.count == 1 ? "Move 1 extra file to the Trash?" : "Move \(cleanUpURLs.count) extra files to the Trash?",
            isPresented: $confirmsCleanUp,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trash(cleanUpURLs) }
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

    /// Only the `transcript.md` of a session folder Roger wrote has extra
    /// files. Anywhere else, other files that happen to match are left alone.
    private func refresh() {
        let lists = LibraryActions.listsExtraFiles(
            item,
            layout: coordinator.appState.libraryLayout,
            extraFolders: coordinator.appState.extraScanFolders
        )
        files = lists ? MeetingExtraFiles.find(in: item.folderURL) : []
    }

    /// Checks the meeting again, lists the folder again and moves only
    /// files that are still trashable extra files and that the user chose.
    /// Nothing moves when the meeting is now locked or unfinished; then the
    /// user is told why.
    private func trash(_ urls: [URL]) {
        guard mayTrash else {
            refresh()
            errorText = LibraryActions.extraFilesBusyMessage
            return
        }
        refresh()
        let current = Set(trashable.map { LibraryPath.canonical($0.url) })
        let allowed = urls.filter { current.contains(LibraryPath.canonical($0)) }
        let failed = LibraryActions.moveToTrash(allowed)
        refresh()
        errorText = LibraryActions.trashFailureMessage(failed)
    }
}
