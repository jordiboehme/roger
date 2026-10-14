import Foundation
import Testing
@testable import RogerKit

struct LibraryScannerTests {
    private let date = KitFixtures.base

    @Test func scansEveryKindAndPlace() throws {
        let home = try TempDir.make()
        defer { TempDir.remove(home) }
        let layout = LibraryLayout(root: home.appendingPathComponent("Library", isDirectory: true))
        try KitFixtures.log(in: layout, at: date, text: "Called the supplier", audio: true)
        try KitFixtures.meeting(in: layout.monthFolder(.meetings, for: date), name: "2026-09-21 16-00", at: date, text: "Welcome")
        try KitFixtures.transcript(at: layout.monthFolder(.transcripts, for: date).appendingPathComponent("talk.mp4.md"), at: date, title: "Talk", text: "Hello")
        let extra = home.appendingPathComponent("Roger Recordings", isDirectory: true)
        try KitFixtures.meeting(in: extra, name: "2025-01-02 10-00", at: date, text: "Old")
        let external = try KitFixtures.transcript(at: home.appendingPathComponent("Media/clip.m4a.md"), at: date, title: "Clip", text: "Hi")

        let items = LibraryScanner.scanAll(
            scope: LibraryScanScope(layout: layout, extraFolders: [extra]),
            externalFiles: [external]
        )
        #expect(items.filter { $0.kind == .log }.count == 1)
        #expect(items.filter { $0.kind == .meeting }.count == 2)
        #expect(items.filter { $0.kind == .transcript }.count == 2)
        let log = try #require(items.first { $0.kind == .log })
        #expect(log.audioFiles.map(\.lastPathComponent) == [KitFixtures.stem(date) + ".m4a"])
    }

    @Test func hiddenFilesAndTheRogerFolderAreNoItems() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let roger = root.appendingPathComponent(".roger", isDirectory: true)
        try FileManager.default.createDirectory(at: roger, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: roger.appendingPathComponent("changes.jsonl"))
        let folder = layout.monthFolder(.logs, for: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\ntags: [log]\n---\n".utf8).write(to: folder.appendingPathComponent(".draft.md"))
        #expect(LibraryScanner.scanAll(scope: LibraryScanScope(layout: layout, extraFolders: []), externalFiles: []).isEmpty)
    }

    @Test func anOverlappingExtraFolderListsEachItemOnce() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let month = layout.monthFolder(.meetings, for: date)
        try KitFixtures.meeting(in: month, name: "2026-09-21 16-00", at: date, text: "Welcome")
        let items = LibraryScanner.scanAll(
            scope: LibraryScanScope(layout: layout, extraFolders: [month]),
            externalFiles: []
        )
        #expect(items.count == 1)
    }

    @Test func unfinishedSessionIsAnItemWithoutMarkdown() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let session = layout.monthFolder(.meetings, for: date).appendingPathComponent("2026-09-21 16-00", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data().write(to: session.appendingPathComponent("mic-001.caf"))
        let item = try #require(LibraryScanner.scanAll(scope: LibraryScanScope(layout: layout, extraFolders: []), externalFiles: []).first)
        #expect(item.isUnfinished)
        #expect(!item.hasMarkdown)
        #expect(item.title == "Unfinished meeting 2026-09-21 16:00")
    }
}
