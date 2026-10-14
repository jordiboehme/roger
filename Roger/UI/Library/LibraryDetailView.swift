import AppKit
import ImageIO
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
    @State private var rename = LibraryRenameState()
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
            Group {
                if model.isEditing {
                    TextEditor(text: $model.draft)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                } else {
                    preview
                }
            }
            // A click below the header ends a rename, like in Finder.
            .simultaneousGesture(TapGesture().onEnded { endRenameByClick() })
        }
        .task(id: item) { await load() }
        .onAppear { consumeRenameRequest() }
        .onChange(of: model.renameRequest) { _, _ in consumeRenameRequest() }
        .onChange(of: titleFocused) { _, focused in
            // Focus moved away (a click in the list, the sidebar or the
            // search field): commit, like Finder. After Return or Esc this
            // does nothing.
            if !focused { commitRename() }
        }
        .alert("This file changed on disk", isPresented: $showsConflict) {
            Button("Overwrite", role: .destructive) { save(overwrite: true) }
            Button("Discard my changes") {
                cancelEditing()
                reloadNow()
            }
            Button("Keep Editing", role: .cancel) {}
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
            if rename.isActive {
                TextField("Title", text: $rename.draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { rename.cancel() }
                    // Safety net when the field goes away without losing
                    // focus first; after Return or Esc this does nothing.
                    .onDisappear { commitRename() }
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
                Self.openMedia(url)
            } label: {
                Label("Open Audio", systemImage: "play.circle")
            }
        } else if item.audioFiles.count > 1 {
            Menu {
                ForEach(item.audioFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { Self.openMedia(url) }
                }
            } label: {
                Label("Open Audio", systemImage: "play.circle")
            }
            .fixedSize()
        }
    }

    /// Opens audio or video; any other file is only shown in the Finder,
    /// so a `sources` entry can never run a script or an app.
    private static func openMedia(_ url: URL) {
        switch LibraryActions.mediaOpening(for: url) {
        case .open: NSWorkspace.shared.open(url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
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
                    if item.kind == .meeting {
                        LibraryExtraFilesSection(item: item, model: model)
                    }
                    let baseURL = item.url.deletingLastPathComponent()
                    LibraryMarkdownView(
                        blocks: LibraryMarkdown.blocks(from: document.body, baseURL: baseURL),
                        terms: model.searchTerms,
                        baseURL: baseURL
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
        rename.cancel()
        reloadNow()
        guard let document else { return }
        model.beginEditing(item, document: document)
    }

    private func cancelEditing() {
        model.editingItem = nil
    }

    /// Checks the active meeting folder again: a recording may have started
    /// in this folder since editing began.
    private func save(overwrite: Bool) {
        do {
            let outcome = try model.saveEdit(
                overwrite: overwrite,
                activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder
            )
            switch outcome {
            case .saved:
                coordinator.libraryChanges.recordWritten(
                markdownURL: item.url, kind: item.kind, root: coordinator.appState.libraryLayout.root
            )
                // The new modification date, or the next save sees this
                // write as a change by another app.
                reloadNow()
                let written = item
                Task { await model.didWrite(written) }
            case .changedOnDisk:
                showsConflict = true
            case .missing, .notEditable:
                // Edit mode stays, so the text can still be copied.
                actionError = outcome.failureMessage
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
        rename.begin(title: item.title)
        titleFocused = true
    }

    private func endRenameByClick() {
        guard rename.isActive else { return }
        commitRename()
        titleFocused = false
    }

    /// Checks the active meeting folder again, like `save`: a recording
    /// may have started in this folder since the rename began. Runs at
    /// most once per rename (`LibraryRenameState`).
    private func commitRename() {
        guard let title = rename.commit() else { return }
        guard canEdit else {
            actionError = LibraryModel.EditSaveOutcome.notEditable.failureMessage
            return
        }
        do {
            try LibraryDocumentEditor.rename(fileAt: item.url, to: title)
            coordinator.libraryChanges.recordWritten(
                markdownURL: item.url, kind: item.kind, root: coordinator.appState.libraryLayout.root
            )
            reloadNow()
            let written = item
            Task { await model.didWrite(written) }
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
    /// The folder of the Markdown file; screenshots open only from inside it.
    let baseURL: URL

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
                    LibraryThumbnail(url: url, alt: alt, folder: baseURL)
                }
            }
        }
    }
}

/// A screenshot in the preview. Decoded off the main actor as a small
/// thumbnail. A click opens it in Preview, never in the file's default app,
/// and only when it really is an image.
struct LibraryThumbnail: View {
    let url: URL
    let alt: String
    /// The folder of the Markdown file.
    let folder: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { Self.openInPreview(url, folder: folder) }
                    .help(alt)
            } else {
                Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = url
        image = nil
        let cgImage = await Task.detached { Self.thumbnail(of: url, maxPixelSize: 720) }.value
        // The view may show another image by now; an old one must not win.
        guard !Task.isCancelled else { return }
        image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
    }

    nonisolated private static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Checks the file again right before opening: no symlink, and still
    /// inside the Markdown file's folder. Otherwise nothing happens.
    private static func openInPreview(_ url: URL, folder: URL) {
        guard LibraryActions.mayOpenImage(url, inside: folder) else { return }
        let url = LibraryPath.canonicalURL(url)
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}
