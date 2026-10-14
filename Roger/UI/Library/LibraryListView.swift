import SwiftUI

/// The middle column: items grouped by day (date sorts) with sticky
/// headers, multi-selection with Cmd and Shift.
struct LibraryListView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel
    @State private var pendingTrash: LibraryActions.TrashPlan?
    @State private var pendingTrashItems: [LibraryItem] = []
    @State private var message: String?
    @FocusState private var listFocused: Bool
    /// Focus goes to the list once, after the first load.
    @State private var focusedOnce = false

    private var commands: LibraryCommands {
        LibraryCommands(model: model, coordinator: coordinator)
    }

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                if section.title.isEmpty {
                    rows(section.items)
                } else {
                    Section(section.title) {
                        rows(section.items)
                    }
                }
            }
        }
        .listStyle(.inset)
        // Rows added to an empty list keep the table's first row height,
        // so their second and third lines were cut off until the next
        // layout. A new list once there are rows measures each row.
        .id(model.results.isEmpty)
        .focused($listFocused)
        .onChange(of: model.results.isEmpty) { _, isEmpty in
            // The rebuilt list is not first responder. Give it the focus
            // once, on the first load, so the arrow keys, Return and
            // Cmd-Backspace work without a click. Later rebuilds (after a
            // search without results) leave the focus where it is.
            guard !isEmpty, !focusedOnce, model.appliedSearch.isEmpty else { return }
            focusedOnce = true
            DispatchQueue.main.async { listFocused = true }
        }
        .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
            let items = commands.items(ids)
            if !items.isEmpty {
                Button("Open") { commands.open(items) }
                Button("Reveal in Finder") { commands.reveal(items) }
                Divider()
                Button("Copy Path") { commands.copyPaths(items) }
                Button("Copy Folder Path") { commands.copyFolderPaths(items) }
                if items.count == 1, let item = items.first, commands.canRename(item) {
                    Divider()
                    Button("Rename…") {
                        model.selection = [item.id]
                        model.renameRequest = item.id
                    }
                }
                Divider()
                Button("Move to Trash") { requestTrash(items) }
            }
        } primaryAction: { ids in
            // Return and double-click.
            commands.open(commands.items(ids))
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            // Cmd-Backspace, only while the list has focus, so it never
            // fires in the search field or the editor.
            guard press.modifiers.contains(.command), !model.selection.isEmpty, !model.isEditing else { return .ignored }
            requestTrash(model.selectedItems)
            return .handled
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    commands.copyPaths(model.selectedItems)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the paths of the selected files (⇧⌘C)")
                .disabled(model.selection.isEmpty || model.isEditing)

                Button {
                    commands.reveal(model.selectedItems)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
                .disabled(model.selection.isEmpty || model.isEditing)

                Button {
                    requestTrash(model.selectedItems)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .help("Move to Trash (⌘⌫)")
                .disabled(model.selection.isEmpty || model.isEditing)
            }
        }
        .confirmationDialog(
            pendingTrash?.confirmationTitle ?? "",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let confirmed = pendingTrash {
                    // Plan again: a meeting may have started finalising
                    // while the question was open. Move only what was
                    // confirmed and is still allowed.
                    runTrash(commands.trashPlan(for: pendingTrashItems).limited(to: confirmed), items: pendingTrashItems)
                }
                pendingTrash = nil
                pendingTrashItems = []
            }
            Button("Cancel", role: .cancel) {
                pendingTrash = nil
                pendingTrashItems = []
            }
        } message: {
            Text("The whole meeting folder goes to the Trash, with its audio, screenshots and transcript. You can put it back from the Trash.")
        }
        .alert("Library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
        .disabled(model.isEditing)
        .overlay { overlay }
    }

    private func rows(_ items: [LibraryItem]) -> some View {
        ForEach(items) { item in
            LibraryItemRow(item: item, showsDate: !model.sort.isByDate)
                .tag(item.id)
                .onDrag {
                    NSItemProvider(object: item.url as NSURL)
                }
        }
    }

    /// Logs and transcripts go straight to the Trash; a plan with meeting
    /// folders asks first. Nothing moves while a body is edited.
    private func requestTrash(_ items: [LibraryItem]) {
        guard !model.isEditing, !items.isEmpty else { return }
        let plan = commands.trashPlan(for: items)
        if plan.urls.isEmpty {
            message = LibraryActions.trashSkippedMessage(plan)
            return
        }
        if plan.needsConfirmation {
            pendingTrashItems = items
            pendingTrash = plan
        } else {
            runTrash(plan, items: items)
        }
    }

    private func runTrash(_ plan: LibraryActions.TrashPlan, items: [LibraryItem]) {
        // Editing may have started while the question was open.
        guard !model.isEditing else { return }
        let failed = LibraryActions.moveToTrash(plan.urls)
        coordinator.libraryChanges.recordDeleted(
            LibraryChangeRecorder.trashedItems(items, plan: plan, failed: failed)
        )
        model.selection = []
        if plan.meetingFolderCount > 0 {
            // A trashed unfinished meeting must leave the popover banner and
            // the Unfinished list now, not after the next recording.
            coordinator.refreshPendingMeetingSessions()
        }
        message = LibraryActions.trashFailureMessage(failed) ?? LibraryActions.trashSkippedMessage(plan)
    }

    @ViewBuilder private var overlay: some View {
        if model.isLoading {
            ProgressView("Reading the library")
        } else if model.results.isEmpty {
            LibraryEmptyStateView(state: LibraryEmptyState.make(
                sidebar: model.sidebar,
                searchText: model.appliedSearch,
                dateFilter: model.dateFilter
            ))
        }
    }
}

/// Type icon, title, first line, time, duration and markers for audio,
/// screenshots and speakers. Log entries show their text in place of the
/// title (`LibraryFormat.rowText`).
struct LibraryItemRow: View {
    let item: LibraryItem
    /// Title and duration sorts have no day headers, so rows show the date.
    let showsDate: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(item.isUnfinished ? Color.orange : Color.secondary)
                .frame(width: 18)
            let text = LibraryFormat.rowText(for: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let preview = text.preview {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(showsDate
                         ? "\(LibraryFormat.longDate(item.date)) \(LibraryFormat.time(item.date))"
                         : LibraryFormat.time(item.date))
                    if let seconds = item.durationSeconds {
                        Text(LibraryFormat.duration(seconds))
                    }
                    if item.hasAudio {
                        Image(systemName: "waveform").help("Has audio")
                    }
                    if item.screenshotCount > 0 {
                        Label("\(item.screenshotCount)", systemImage: "photo").help("Screenshots")
                    }
                    if let speakers = item.speakerCount, speakers > 1 {
                        Label("\(speakers)", systemImage: "person.2").help("Speakers")
                    }
                    if item.isUnfinished {
                        Text("Unfinished").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }
}
