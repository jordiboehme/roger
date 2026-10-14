import Foundation
import Testing
@testable import RogerKit

struct ReconcileTests {
    private let day: TimeInterval = 86_400

    private func items(_ layout: LibraryLayout, extra: [URL] = [], external: [URL] = []) -> [LibraryItem] {
        LibraryScanner.scanAll(scope: LibraryScanScope(layout: layout, extraFolders: extra), externalFiles: external)
    }

    @Test func firstFillIsInRecordingDateOrder() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let base = KitFixtures.base
        try KitFixtures.log(in: layout, at: base.addingTimeInterval(2 * day), text: "newest")
        try KitFixtures.meeting(in: layout.monthFolder(.meetings, for: base), name: "2026-09-21 16-00", at: base, text: "oldest")
        try KitFixtures.transcript(at: layout.monthFolder(.transcripts, for: base).appendingPathComponent("talk.mp4.md"), at: base.addingTimeInterval(day), title: "Talk", text: "middle")

        let written = try await ChangeLog(root: root).reconcile(items: items(layout))
        #expect(written.map(\.seq) == [1, 2, 3])
        #expect(written.map(\.kind) == [.meeting, .transcript, .log])
        #expect(written.allSatisfy { $0.event == .created })
        #expect(written[0].key.hasSuffix("/2026-09-21 16-00"))
        #expect(written[0].path.hasSuffix("/2026-09-21 16-00/transcript.md"))
        #expect(written[1].key.hasSuffix("/talk.mp4"))
    }

    @Test func catchUpAddsOnlyMissingItems() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let log = ChangeLog(root: root)
        try KitFixtures.log(in: layout, at: KitFixtures.base, text: "one")
        try await log.reconcile(items: items(layout))
        #expect(try await log.reconcile(items: items(layout)).isEmpty)
        try KitFixtures.log(in: layout, at: KitFixtures.base.addingTimeInterval(60), text: "two")
        let added = try await log.reconcile(items: items(layout))
        #expect(added.map(\.seq) == [2])
    }

    @Test func deletedKeyComesBackOnlyWhenTheFileExistsAgain() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let log = ChangeLog(root: root)
        let md = try KitFixtures.log(in: layout, at: KitFixtures.base, text: "one")
        try await log.reconcile(items: items(layout))
        let subject = ChangeKey.subject(markdownURL: md, kind: .log, root: root)
        try await log.record(.deleted, subject)
        try FileManager.default.removeItem(at: md)
        #expect(try await log.reconcile(items: items(layout)).isEmpty)
        try KitFixtures.log(in: layout, at: KitFixtures.base, text: "one again")
        let back = try await log.reconcile(items: items(layout))
        #expect(back.map(\.event) == [.created])
        #expect(back.map(\.seq) == [3])
    }

    @Test func unfinishedSessionsAreNotLogged() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let session = layout.monthFolder(.meetings, for: KitFixtures.base).appendingPathComponent("2026-09-21 16-00", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data().write(to: session.appendingPathComponent("mic-001.caf"))
        #expect(try await ChangeLog(root: root).reconcile(items: items(layout)).isEmpty)
    }

    @Test func emptyLibraryGetsAnEmptyLog() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        try await ChangeLog(root: root).reconcile(items: [])
        #expect(FileManager.default.fileExists(atPath: ChangeLogFile.url(root: root).path))
    }

    @Test func externalAndExtraFolderItemsGetExternalKeys() async throws {
        let home = try TempDir.make()
        defer { TempDir.remove(home) }
        let layout = LibraryLayout(root: home.appendingPathComponent("Library", isDirectory: true))
        let extra = home.appendingPathComponent("Roger Recordings", isDirectory: true)
        try KitFixtures.meeting(in: extra, name: "2025-01-02 10-00", at: KitFixtures.base, text: "old")
        let clip = try KitFixtures.transcript(at: home.appendingPathComponent("Media/clip.m4a.md"), at: KitFixtures.base, title: "Clip", text: "x")
        let written = try await ChangeLog(root: layout.root).reconcile(items: items(layout, extra: [extra], external: [clip]))
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.key.hasPrefix("External/") && $0.path.hasPrefix("/") })
    }

    @Test func writtenIsCreatedThenUpdated() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let log = ChangeLog(root: root)
        let subject = ChangeSubject(kind: .meeting, key: "Meetings/2026/10/s", path: "Meetings/2026/10/s/transcript.md")
        #expect(try await log.record(.written, subject)?.event == .created)
        #expect(try await log.record(.written, subject)?.event == .updated)
        #expect(try await log.record(.deleted, subject)?.event == .deleted)
        #expect(try await log.record(.deleted, subject) == nil)
        #expect(try await log.record(.written, subject)?.event == .created)
    }

    @Test func deletingAnUnknownKeyWritesNothing() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let subject = ChangeSubject(kind: .log, key: "Logs/2026/10/x", path: "Logs/2026/10/x.md")
        #expect(try await ChangeLog(root: root).record(.deleted, subject) == nil)
    }
}
