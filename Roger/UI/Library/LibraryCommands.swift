import AppKit

/// AppKit side of the library actions, used by the list, its context menu
/// and the toolbar. Nothing runs while a body is edited (Ruling 7).
@MainActor
struct LibraryCommands {
    let model: LibraryModel
    let coordinator: AppCoordinator

    func items(_ ids: Set<LibraryItem.ID>) -> [LibraryItem] {
        model.results.filter { ids.contains($0.id) }
    }

    /// Default app for `.md`. An unfinished meeting opens its folder in Finder.
    func open(_ items: [LibraryItem]) {
        guard !model.isEditing else { return }
        for item in items {
            if item.hasMarkdown {
                NSWorkspace.shared.open(item.url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
            }
        }
    }

    func reveal(_ items: [LibraryItem]) {
        guard !model.isEditing, !items.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(LibraryActions.fileURLs(for: items))
    }

    func copyPaths(_ items: [LibraryItem]) {
        guard !model.isEditing else { return }
        copy(LibraryActions.pathsText(for: items))
    }

    func copyFolderPaths(_ items: [LibraryItem]) {
        guard !model.isEditing else { return }
        copy(LibraryActions.folderPathsText(for: items))
    }

    /// Empty while a body is edited.
    func trashPlan(for items: [LibraryItem]) -> LibraryActions.TrashPlan {
        guard !model.isEditing else { return LibraryActions.TrashPlan() }
        return LibraryActions.trashPlan(
            for: items,
            layout: coordinator.appState.libraryLayout,
            extraFolders: coordinator.appState.extraScanFolders,
            activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder
        )
    }

    /// Rename only where the detail pane would allow it.
    func canRename(_ item: LibraryItem) -> Bool {
        !model.isEditing
            && LibraryDocumentEditor.canEdit(item, activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
