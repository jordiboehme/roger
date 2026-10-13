import Foundation
import Testing
@testable import Roger

private final class FakeLibraryIndex: LibraryIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LibraryItem]
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(_ items: [LibraryItem]) {
        stored = items
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        changes = stream
        self.continuation = continuation
    }

    func items() async -> [LibraryItem] { lock.withLock { stored } }
    func search(_ query: LibraryQuery) async -> [LibraryItem] { query.apply(to: lock.withLock { stored }) }

    func set(_ items: [LibraryItem]) {
        lock.withLock { stored = items }
        continuation.yield()
    }
}

@MainActor
struct LibraryModelTests {
    private let items = [
        LibraryFixtures.item("log1", kind: .log, body: "supplier call"),
        LibraryFixtures.item("log2", kind: .log),
        LibraryFixtures.item("meeting", kind: .meeting, folder: "/RogerFixtures/Meetings/2026/10/s"),
    ]

    @Test func countsPerKind() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        await model.reload()
        #expect(!model.isLoading)
        #expect(model.totalCount == 3)
        #expect(model.counts[.log] == 2)
        #expect(model.counts[.meeting] == 1)
        #expect(model.counts[.transcript] == nil)
    }

    @Test func sidebarKindFiltersResults() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        model.sidebar = .kind(.meeting)
        await model.reload()
        #expect(model.results.map(\.title) == ["meeting"])
        #expect(model.totalCount == 3)
    }

    @Test func searchAppliesAfterCommit() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        model.searchText = "SUPPLIER"
        await model.commitSearch()
        #expect(model.appliedSearch == "SUPPLIER")
        #expect(model.results.map(\.title) == ["log1"])
        #expect(model.searchTerms == ["supplier"])
    }

    /// The index stores canonical paths (`/private/var/...`), while
    /// "Show in Library" may hand over the `/var/...` spelling of the same
    /// file. The pending selection must still find it.
    @Test func pendingSelectionWaitsForItem() async throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let file = folder.appendingPathComponent("late.md")
        try "# late\n".write(to: file, atomically: true, encoding: .utf8)

        let canonical = LibraryPath.canonical(file)
        try #require(canonical.hasPrefix("/private/var/"))
        let varSpelling = String(canonical.dropFirst("/private".count))
        #expect(varSpelling.hasPrefix("/var/"))
        #expect(varSpelling != canonical)

        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        model.sidebar = .kind(.meeting)
        model.searchText = "nothing"
        await model.commitSearch()

        let late = LibraryFixtures.item(
            "late", kind: .log,
            folder: (canonical as NSString).deletingLastPathComponent
        )
        #expect(late.id == canonical)
        model.select(url: URL(fileURLWithPath: varSpelling))
        await model.reload()
        #expect(model.selection.isEmpty)
        #expect(model.sidebar == .all)
        #expect(model.searchText == "")
        #expect(model.appliedSearch == "")

        fake.set(items + [late])
        await model.reload()
        #expect(model.selection == [canonical])
    }

    @Test func selectionDropsItemsThatAreGone() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        await model.reload()
        model.selection = [items[0].id, items[1].id]
        #expect(model.selectedItems.count == 2)
        fake.set([items[1], items[2]])
        await model.reload()
        #expect(model.selection == [items[1].id])
    }

    @Test func editingKeepsTheSelection() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        await model.reload()
        model.selection = [items[0].id]
        model.editingItem = items[0]
        fake.set([items[1]])
        await model.reload()
        #expect(model.selection == [items[0].id])
    }
}
