import Foundation
import Testing
@testable import RogerKit

struct ItemSearchTests {
    private let base = KitFixtures.base

    private func library() throws -> (URL, [LibraryItem]) {
        let root = try TempDir.make()
        let layout = LibraryLayout(root: root)
        try KitFixtures.log(in: layout, at: base, text: "Called the Supplier about the delayed shipment")
        try KitFixtures.log(in: layout, at: base.addingTimeInterval(60), text: "Supplier invoice arrived")
        try KitFixtures.meeting(in: layout.monthFolder(.meetings, for: base), name: "2026-09-21 16-00", at: base.addingTimeInterval(120), text: "We talked about the supplier and the shipment")
        let unfinished = layout.monthFolder(.meetings, for: base).appendingPathComponent("2026-09-21 17-00", isDirectory: true)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data().write(to: unfinished.appendingPathComponent("mic-001.caf"))
        return (root, LibraryScanner.scanAll(scope: LibraryScanScope(layout: layout, extraFolders: []), externalFiles: []))
    }

    @Test func everyWordMustMatchCaseInsensitive() throws {
        let (root, items) = try library()
        defer { TempDir.remove(root) }
        let hits = ItemSearch.search("SUPPLIER shipment", in: items, kind: nil, limit: 20)
        #expect(hits.map(\.item.kind) == [.meeting, .log])
    }

    @Test func kindAndLimit() throws {
        let (root, items) = try library()
        defer { TempDir.remove(root) }
        #expect(ItemSearch.search("supplier", in: items, kind: .log, limit: 20).count == 2)
        #expect(ItemSearch.search("supplier", in: items, kind: nil, limit: 1).map(\.item.kind) == [.meeting])
    }

    @Test func unfinishedMeetingsAreNotFound() throws {
        let (root, items) = try library()
        defer { TempDir.remove(root) }
        let unfinished = try #require(items.first { $0.kind == .meeting && !$0.hasMarkdown })
        #expect(unfinished.searchText.contains("unfinished"))
        let hits = ItemSearch.search("unfinished", in: items, kind: nil, limit: 20)
        #expect(!hits.contains { $0.item.id == unfinished.id })
        #expect(hits.isEmpty)
        #expect(ItemSearch.search("   ", in: items, kind: nil, limit: 20).isEmpty)
    }

    @Test func snippetKeepsCaseAroundTheMatch() throws {
        let (root, items) = try library()
        defer { TempDir.remove(root) }
        let hit = try #require(ItemSearch.search("delayed", in: items, kind: nil, limit: 20).first)
        #expect(hit.snippet.contains("Called the Supplier about the delayed shipment"))
        #expect(!hit.snippet.contains("\n"))
        #expect(hit.snippet.count <= ItemSearch.snippetLength)
    }

    @Test func snippetOfALongTextStaysWithinTheLimitWithMarkers() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let long = String(repeating: "before ", count: 100) + "NEEDLE " + String(repeating: "after ", count: 100)
        try KitFixtures.log(in: LibraryLayout(root: root), at: base, text: long)
        let items = LibraryScanner.scanAll(scope: LibraryScanScope(layout: LibraryLayout(root: root), extraFolders: []), externalFiles: [])
        let hit = try #require(ItemSearch.search("needle", in: items, kind: nil, limit: 5).first)
        #expect(hit.snippet.hasPrefix("...") && hit.snippet.hasSuffix("..."))
        #expect(hit.snippet.contains("NEEDLE"))
        #expect(hit.snippet.count <= ItemSearch.snippetLength)
    }
}
