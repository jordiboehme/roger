import Foundation
import Observation

/// Which list the library shows.
enum LibrarySidebarSelection: Hashable, Sendable {
    case all
    case kind(LibraryItemKind)
    /// `AppCoordinator.pendingMeetingSessions`, not index items.
    case unfinished

    /// Search, the date filter and sort apply to this list. Unfinished
    /// meetings are a plain list without them.
    var usesFilters: Bool { self != .unfinished }
}

/// State of the library window over a `LibraryIndex`. Views read it and
/// set its filters; it asks the index again on every change.
@MainActor
@Observable
final class LibraryModel {
    private(set) var index: any LibraryIndex

    var sidebar: LibrarySidebarSelection = .all {
        didSet { if sidebar != oldValue { scheduleReload() } }
    }
    /// What the search field shows. Applied after `searchDebounce`.
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var dateFilter: LibraryDateFilter = .any {
        didSet { if dateFilter != oldValue { scheduleReload() } }
    }
    var sort: LibrarySort = .newestFirst {
        didSet { if sort != oldValue { scheduleReload() } }
    }
    var selection: Set<LibraryItem.ID> = [] {
        didSet {
            // Selecting anything else ends the pin.
            if let pinnedID, selection != [pinnedID] { self.pinnedID = nil }
        }
    }
    /// The item whose body the detail pane is editing. The list is locked
    /// meanwhile, and the detail pane keeps showing this item even when a
    /// filter or a refresh hides it, so unsaved text is never dropped.
    /// "Show in Library" and a new index wait until editing ends.
    var editingItem: LibraryItem? {
        didSet {
            guard oldValue != nil, editingItem == nil else { return }
            editBase = nil
            draft = ""
            if let url = deferredSelectionURL {
                deferredSelectionURL = nil
                select(url: url)
            } else {
                scheduleReload()
            }
        }
    }
    var isEditing: Bool { editingItem != nil }
    /// The file as read when editing started; `saveEdit` checks it for
    /// changes by other apps.
    private(set) var editBase: LibraryDocument?
    /// The body text in the editor.
    var draft = ""
    /// True when the editor holds text that differs from the file.
    var hasUnsavedChanges: Bool {
        guard let editBase else { return false }
        return draft != editBase.body
    }
    /// Set by the Rename menu item. The detail pane of that item starts
    /// renaming and clears it.
    var renameRequest: LibraryItem.ID?

    private(set) var results: [LibraryItem] = []
    private(set) var counts: [LibraryItemKind: Int] = [:]
    private(set) var totalCount = 0
    private(set) var isLoading = true
    /// The library folder does not exist (deleted, or on a drive that is
    /// not connected).
    private(set) var libraryMissing = false
    /// The search text in effect.
    private(set) var appliedSearch = ""
    /// Grows with every reload that was applied (tests check that a write
    /// in a meeting folder does not reload the list).
    private(set) var reloadCount = 0
    /// Per canonical session folder: how often the index reported a change
    /// inside it. Only the Extra files section showing that folder reads
    /// it, so a recording does not redraw the list or the detail body.
    private(set) var sessionFolderChanges: [String: Int] = [:]

    @ObservationIgnored private var pendingSelectionID: String?
    /// The entry that was just saved or renamed. It stays in `results`
    /// (and selected) even when it no longer matches the search or the
    /// filters, until the selection changes.
    @ObservationIgnored private var pinnedID: String?
    /// A `select(url:)` that arrived while a body was edited.
    @ObservationIgnored private var deferredSelectionURL: URL?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let searchDebounce: Duration
    /// Bumped by `replaceIndex`. A reload that started on an older index
    /// throws its results away.
    @ObservationIgnored private var indexGeneration = 0
    /// Every reload takes the next number; one that finishes after a newer
    /// one has been applied throws its results away.
    @ObservationIgnored private var lastStartedReload = 0
    @ObservationIgnored private var lastAppliedReload = 0
    /// While the window is closed, changes are not loaded; `resume()`
    /// loads once.
    @ObservationIgnored private var isPaused = false

    init(index: any LibraryIndex, searchDebounce: Duration = .milliseconds(150)) {
        self.index = index
        self.searchDebounce = searchDebounce
    }

    var query: LibraryQuery {
        var kind: LibraryItemKind?
        if case .kind(let selected) = sidebar { kind = selected }
        return LibraryQuery(kind: kind, dateFilter: dateFilter, searchText: appliedSearch, sort: sort)
    }

    var searchTerms: [String] { query.searchTerms }
    var sections: [LibraryDaySection] { LibraryDayGrouping.sections(results, sort: sort) }
    var selectedItems: [LibraryItem] { results.filter { selection.contains($0.id) } }

    /// Follows the index's changes and loads the first results.
    func start() {
        changeTask?.cancel()
        let stream = index.changes
        changeTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                if self.isPaused { continue }
                await self.handleIndexChange()
            }
        }
        scheduleReload()
    }

    func stop() {
        changeTask?.cancel()
        reloadTask?.cancel()
        searchTask?.cancel()
    }

    /// The window closed: ignore changes until `resume()`. The stream is
    /// still read, not cancelled, because a cancelled `AsyncStream` ends for
    /// good and the store keeps the same index for the next opening.
    func pause() {
        isPaused = true
        reloadTask?.cancel()
        searchTask?.cancel()
    }

    /// The window closed. An edit without changes ends, so the list is not
    /// locked when the window opens again; unsaved text was already saved
    /// or dropped by the close question. Then `pause()`.
    func windowClosed() {
        if isEditing, !hasUnsavedChanges {
            editingItem = nil
        }
        pause()
    }

    /// The window opens again: follow changes and load once. Meeting
    /// folders that changed while it was closed are counted too.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.handleIndexChange(reloadingAlways: true)
        }
    }

    /// The library folder or the extra folders changed.
    func replaceIndex(_ newIndex: any LibraryIndex) {
        stop()
        indexGeneration += 1
        index = newIndex
        isLoading = true
        results = []
        // While editing, the selection stays; the reload after editing
        // ends drops what the new index does not have.
        if !isEditing { selection = [] }
        start()
    }

    // MARK: Editing

    enum EditSaveOutcome: Equatable, Sendable {
        case saved
        /// Another app changed the file. Nothing was written.
        case changedOnDisk
        /// The file is gone. Nothing was written.
        case missing
        /// A meeting is being recorded or finalised in the file's folder. Nothing was written.
        case notEditable

        /// What to tell the user when the text was not saved. The view
        /// asks about `changedOnDisk` with an alert of its own.
        var failureMessage: String? {
            switch self {
            case .saved: return nil
            case .changedOnDisk:
                return "Another app changed this file after you started editing, so your text was not saved. Save it in the library window to choose what to keep."
            case .missing:
                return "The file was moved or deleted, so your text was not saved. Copy it before you cancel."
            case .notEditable:
                return "A meeting is being recorded or finalised in this folder, so your text was not saved. Save again when it is done."
            }
        }
    }

    func beginEditing(_ item: LibraryItem, document: LibraryDocument) {
        editingItem = item
        editBase = document
        draft = document.body
    }

    /// Writes the draft. Editing ends only when it was saved; otherwise the
    /// draft stays so nothing is lost.
    func saveEdit(overwrite: Bool, activeSessionFolder: URL?) throws -> EditSaveOutcome {
        guard let item = editingItem, let base = editBase else { return .missing }
        guard LibraryDocumentEditor.canEdit(item, activeSessionFolder: activeSessionFolder) else { return .notEditable }
        switch try LibraryDocumentEditor.saveBody(draft, of: base, overwrite: overwrite) {
        case .saved:
            pinnedID = item.id
            editingItem = nil
            return .saved
        case .changedOnDisk:
            return .changedOnDisk
        case .missing:
            return .missing
        }
    }

    // MARK: Selection

    /// Shows everything and selects the item at `url` as soon as the index
    /// has it (a log entry written a moment ago may not be indexed yet).
    /// While a body is edited, nothing changes until editing ends.
    func select(url: URL) {
        if isEditing {
            deferredSelectionURL = url
            return
        }
        pendingSelectionID = LibraryPath.canonical(url)
        sidebar = .all
        dateFilter = .any
        searchText = ""
        appliedSearch = ""
        scheduleReload()
    }

    /// Roger wrote this entry's file (rename or save). The index reads it
    /// now, so the header and the row show the new text at once. The entry
    /// stays listed only while it is still the selection: a rename that a
    /// click on another entry ended pins nothing.
    func didWrite(_ item: LibraryItem) async {
        if selection == [item.id] { pinnedID = item.id }
        await index.refresh(paths: [item.url.path])
        await reload()
    }

    func sessionFolderChangeCount(for folder: URL) -> Int {
        sessionFolderChanges[LibraryPath.canonical(folder), default: 0]
    }

    /// The index reported a change. The list reloads only when items
    /// changed; a write in a meeting folder only counts for that folder.
    func handleIndexChange(reloadingAlways: Bool = false) async {
        let change = await index.takeChange()
        if !change.sessionFolders.isEmpty {
            var counts = sessionFolderChanges
            for folder in change.sessionFolders { counts[folder, default: 0] += 1 }
            sessionFolderChanges = counts
        }
        if change.itemsChanged || reloadingAlways { await reload() }
    }

    /// Roger became active: the library folder may have come back.
    func recheckLibraryRoot() async {
        await index.recheckRoot()
        await reload()
    }

    func commitSearch() async {
        appliedSearch = searchText
        await reload()
    }

    func reload() async {
        let index = self.index
        let generation = indexGeneration
        lastStartedReload += 1
        let reloadNumber = lastStartedReload
        let all = await index.items()
        let found = await index.search(query)
        let missing = await index.libraryRootMissing()
        // Drop the results when the index was replaced, this reload was
        // cancelled or a newer reload has already been applied.
        guard generation == indexGeneration, !Task.isCancelled, reloadNumber > lastAppliedReload else { return }
        lastAppliedReload = reloadNumber
        reloadCount += 1
        // Only changed values are set, so an equal reload redraws nothing.
        let newCounts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        if counts != newCounts { counts = newCounts }
        if totalCount != all.count { totalCount = all.count }
        if libraryMissing != missing { libraryMissing = missing }
        var shown = found
        if let pinned = pinnedID, !found.contains(where: { $0.id == pinned }) {
            if let item = all.first(where: { $0.id == pinned }) {
                shown = LibraryQuery.sorted(found + [item], by: query.sort)
            } else {
                // Gone from the index (moved or deleted).
                pinnedID = nil
            }
        }
        if results != shown { results = shown }
        if isLoading { isLoading = false }
        let ids = Set(shown.map(\.id))
        // While editing, the selection and any pending one stay as they are.
        guard !isEditing else { return }
        if let pending = pendingSelectionID, ids.contains(pending) {
            selection = [pending]
            pendingSelectionID = nil
        } else {
            let kept = selection.intersection(ids)
            if kept != selection { selection = kept }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.reload()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let delay = searchDebounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commitSearch()
        }
    }
}
