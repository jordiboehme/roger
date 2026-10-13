import Foundation
import Observation

/// Which list the library shows.
enum LibrarySidebarSelection: Hashable, Sendable {
    case all
    case kind(LibraryItemKind)
    /// `AppCoordinator.pendingMeetingSessions`, not index items.
    case unfinished
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
    var selection: Set<LibraryItem.ID> = []
    /// The item whose body the detail pane is editing. The list is locked
    /// meanwhile, and the detail pane keeps showing this item even when a
    /// filter or a refresh hides it, so unsaved text is never dropped.
    var editingItem: LibraryItem?
    var isEditing: Bool { editingItem != nil }
    /// Set by the Rename menu item. The detail pane of that item starts
    /// renaming and clears it.
    var renameRequest: LibraryItem.ID?

    private(set) var results: [LibraryItem] = []
    private(set) var counts: [LibraryItemKind: Int] = [:]
    private(set) var totalCount = 0
    private(set) var isLoading = true
    /// The search text in effect.
    private(set) var appliedSearch = ""

    @ObservationIgnored private var pendingSelectionID: String?
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
                await self.reload()
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

    /// The window opens again: follow changes and load once.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        scheduleReload()
    }

    /// The library folder or the extra folders changed.
    func replaceIndex(_ newIndex: any LibraryIndex) {
        stop()
        indexGeneration += 1
        index = newIndex
        isLoading = true
        results = []
        selection = []
        start()
    }

    /// Shows everything and selects the item at `url` as soon as the index
    /// has it (a log entry written a moment ago may not be indexed yet).
    func select(url: URL) {
        pendingSelectionID = LibraryPath.canonical(url)
        sidebar = .all
        dateFilter = .any
        searchText = ""
        appliedSearch = ""
        scheduleReload()
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
        // Drop the results when the index was replaced, this reload was
        // cancelled or a newer reload has already been applied.
        guard generation == indexGeneration, !Task.isCancelled, reloadNumber > lastAppliedReload else { return }
        lastAppliedReload = reloadNumber
        counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        totalCount = all.count
        results = found
        isLoading = false
        let ids = Set(found.map(\.id))
        if let pending = pendingSelectionID, ids.contains(pending) {
            selection = [pending]
            pendingSelectionID = nil
        } else if !isEditing {
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
