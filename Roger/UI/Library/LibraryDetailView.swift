import AppKit
import SwiftUI

/// The right column: one item's detail, or a summary of a multi-selection.
struct LibraryDetailView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        let selected = model.selectedItems
        // One branch for both cases, so an edit in progress keeps its state.
        let shown = model.editingItem ?? (selected.count == 1 ? selected.first : nil)
        if let item = shown {
            LibraryItemDetail(item: item, model: model)
                .id(item.id)
        } else if selected.count > 1 {
            ContentUnavailableView(
                "\(selected.count) Items Selected",
                systemImage: "square.stack",
                description: Text("Drag them, copy their paths or move them to the Trash.")
            )
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "books.vertical",
                description: Text("Select an entry to read it here.")
            )
        }
    }
}

/// Header (title, click to rename; metadata; Open Audio; Edit), then the
/// preview or the body editor. Reads the file from disk each time the item
/// is shown or changes.
struct LibraryItemDetail: View {
    @Environment(AppCoordinator.self) private var coordinator
    let item: LibraryItem
    @Bindable var model: LibraryModel

    @State private var document: LibraryDocument?
    @State private var loadError: String?
    @State private var isRenaming = false
    @State private var titleDraft = ""
    @State private var draft = ""
    @State private var editBase: LibraryDocument?
    @State private var showsConflict = false
    @State private var actionError: String?
    @FocusState private var titleFocused: Bool

    private var canEdit: Bool {
        LibraryDocumentEditor.canEdit(item, activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            if model.isEditing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            } else {
                preview
            }
        }
        .task(id: item) { await load() }
        .onAppear { consumeRenameRequest() }
        .onChange(of: model.renameRequest) { _, _ in consumeRenameRequest() }
        .alert("This file changed on disk", isPresented: $showsConflict) {
            Button("Overwrite", role: .destructive) { save(overwrite: true) }
            Button("Discard my changes") {
                cancelEditing()
                reloadNow()
            }
        } message: {
            Text("Another app changed it after you started editing. Overwrite it with your text, or discard your changes?")
        }
        .alert("Roger could not do that", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRenaming {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .onTapGesture { startRename() }
                    .help(canEdit ? "Click to rename. The file name stays the same." : "")
            }
            Text(LibraryFormat.metadataLine(for: item))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                audioButton
                Spacer()
                if model.isEditing {
                    Button("Cancel") { cancelEditing() }
                    Button("Save") { save(overwrite: false) }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                } else if canEdit, document != nil {
                    Button("Edit") { startEditing() }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var audioButton: some View {
        if item.audioFiles.count == 1, let url = item.audioFiles.first {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Audio", systemImage: "play.circle")
            }
        } else if item.audioFiles.count > 1 {
            Menu {
                ForEach(item.audioFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { NSWorkspace.shared.open(url) }
                }
            } label: {
                Label("Open Audio", systemImage: "play.circle")
            }
            .fixedSize()
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if !item.hasMarkdown {
            ContentUnavailableView(
                "Not Transcribed Yet",
                systemImage: "tray.full",
                description: Text("Finalise it under Unfinished in the sidebar.")
            )
        } else if let loadError {
            ContentUnavailableView("Can't Read This File", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if let document {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LibraryMarkdownView(
                        blocks: LibraryMarkdown.blocks(from: document.body, baseURL: item.url.deletingLastPathComponent()),
                        terms: model.searchTerms
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func load() async {
        guard !model.isEditing, item.hasMarkdown else { return }
        let url = item.url
        do {
            document = try await Task.detached { try LibraryDocument.load(url) }.value
            loadError = nil
        } catch {
            document = nil
            loadError = error.localizedDescription
        }
    }

    /// Reads the file now, on the main actor. Used after Roger wrote it,
    /// so the next save compares against Roger's own write.
    private func reloadNow() {
        do {
            document = try LibraryDocument.load(item.url)
            loadError = nil
        } catch {
            document = nil
            loadError = error.localizedDescription
        }
    }

    /// Edits the file as it is on disk right now, not the copy the preview
    /// shows, which may be older.
    private func startEditing() {
        guard canEdit, !model.isEditing else { return }
        isRenaming = false
        reloadNow()
        guard let document else { return }
        editBase = document
        draft = document.body
        model.editingItem = item
    }

    private func cancelEditing() {
        model.editingItem = nil
        editBase = nil
    }

    private func save(overwrite: Bool) {
        guard let base = editBase else { return }
        do {
            switch try LibraryDocumentEditor.saveBody(draft, of: base, overwrite: overwrite) {
            case .saved:
                cancelEditing()
                // The new modification date, or the next save sees this
                // write as a change by another app.
                reloadNow()
            case .changedOnDisk:
                showsConflict = true
            case .missing:
                // Stay in edit mode so the text can still be copied.
                actionError = "The file was moved or deleted, so your text was not saved. Copy it before you cancel."
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func consumeRenameRequest() {
        guard model.renameRequest == item.id else { return }
        model.renameRequest = nil
        startRename()
    }

    private func startRename() {
        guard canEdit, !model.isEditing else { return }
        titleDraft = item.title
        isRenaming = true
        titleFocused = true
    }

    private func commitRename() {
        isRenaming = false
        guard titleDraft != item.title else { return }
        do {
            try LibraryDocumentEditor.rename(fileAt: item.url, to: titleDraft)
            reloadNow()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Headings, paragraphs with inline Markdown and search highlights, and
/// screenshot thumbnails where they appear in the text.
struct LibraryMarkdownView: View {
    let blocks: [LibraryMarkdownBlock]
    let terms: [String]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(LibraryMarkdown.attributed(text, highlighting: terms))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .paragraph(let text):
                    Text(LibraryMarkdown.attributed(text, highlighting: terms))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let alt, let url):
                    LibraryThumbnail(url: url, alt: alt)
                }
            }
        }
    }
}

struct LibraryThumbnail: View {
    let url: URL
    let alt: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help(alt)
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}
