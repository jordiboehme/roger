import Foundation
import Testing
@testable import Roger

@MainActor
struct LibraryChangeRecorderTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// Which root the recorder sees; tests switch it like the settings do.
    @MainActor final class RootBox {
        var root: URL
        init(_ root: URL) { self.root = root }
    }

    private func recorder(_ box: RootBox, registry: URL) -> LibraryChangeRecorder {
        LibraryChangeRecorder(environment: {
            LibraryChangeEnvironment(
                layout: LibraryLayout(root: box.root),
                extraFolders: [],
                externalRegistry: ExternalTranscriptRegistry(fileURL: registry)
            )
        })
    }

    @discardableResult
    private func writeLog(_ root: URL, at date: Date, text: String) throws -> URL {
        let folder = LibraryLayout(root: root).monthFolder(.logs, for: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(LogEntryWriter.baseName(for: date) + ".md")
        let entry = LogEntry(text: text, startedAt: date, endedAt: date.addingTimeInterval(10), presetName: "Log", language: nil)
        try LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func launchCatchUpFillsExistingItems() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        try writeLog(root, at: date, text: "one")
        try writeLog(root, at: date.addingTimeInterval(60), text: "two")
        let recorder = recorder(RootBox(root), registry: home.appendingPathComponent("external.json"))
        recorder.reconcile()
        await recorder.waitUntilIdle()
        let events = try ChangeLogFile.readEvents(root: root)
        #expect(events.map(\.event) == [.created, .created])
        #expect(events.map(\.seq) == [1, 2])
    }

    @Test func writesAreRecordedInCallOrder() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        let recorder = recorder(RootBox(root), registry: home.appendingPathComponent("external.json"))
        recorder.reconcile()
        await recorder.waitUntilIdle()
        var keys: [String] = []
        for i in 0..<10 {
            let url = try writeLog(root, at: date.addingTimeInterval(Double(i) * 60), text: "entry \(i)")
            keys.append(ChangeKey.subject(markdownURL: url, kind: .log, root: root).key)
            recorder.recordWritten(markdownURL: url, kind: .log)
        }
        await recorder.waitUntilIdle()
        let events = try ChangeLogFile.readEvents(root: root)
        #expect(events.map(\.key) == keys)
        #expect(events.allSatisfy { $0.event == .created })
    }

    @Test func rewritingAnItemIsAnUpdate() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        let recorder = recorder(RootBox(root), registry: home.appendingPathComponent("external.json"))
        recorder.reconcile()
        await recorder.waitUntilIdle()
        let session = root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let transcript = session.appendingPathComponent("transcript.md")
        try Data("---\ntags: [meeting, transcript]\n---\n# Meeting\n".utf8).write(to: transcript)
        recorder.recordWritten(markdownURL: transcript, kind: .meeting)
        recorder.recordWritten(markdownURL: transcript, kind: .meeting)
        await recorder.waitUntilIdle()
        let events = try ChangeLogFile.readEvents(root: root)
        #expect(events.map(\.event) == [.created, .updated])
        #expect(events.allSatisfy { $0.key == "Meetings/2026/10/2026-10-13 09-00" })
    }

    @Test func rootChangeFillsTheNewLibrary() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let rootA = home.appendingPathComponent("A", isDirectory: true)
        let rootB = home.appendingPathComponent("B", isDirectory: true)
        try writeLog(rootB, at: date, text: "already in B")
        let box = RootBox(rootA)
        let recorder = recorder(box, registry: home.appendingPathComponent("external.json"))
        recorder.reconcile()
        await recorder.waitUntilIdle()
        recorder.recordWritten(markdownURL: try writeLog(rootA, at: date, text: "in A"), kind: .log)

        // The user picks folder B in Settings; a log entry follows before
        // the settings view calls reconcile().
        box.root = rootB
        let newInB = try writeLog(rootB, at: date.addingTimeInterval(120), text: "new in B")
        recorder.recordWritten(markdownURL: newInB, kind: .log)
        await recorder.waitUntilIdle()

        #expect(try ChangeLogFile.readEvents(root: rootA).count == 1)
        let inB = try ChangeLogFile.readEvents(root: rootB)
        #expect(Set(inB.map(\.key)).count == 2)
        #expect(inB.first?.event == .created)
    }

    @Test func trashedItemIsDeletedOnce() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        let url = try writeLog(root, at: date, text: "one")
        let recorder = recorder(RootBox(root), registry: home.appendingPathComponent("external.json"))
        recorder.reconcile()
        await recorder.waitUntilIdle()
        let item = try #require(LibraryItemReader.item(markdownAt: url, fallbackKind: .log))
        recorder.recordDeleted([item])
        recorder.recordDeleted([item])
        await recorder.waitUntilIdle()
        #expect(try ChangeLogFile.readEvents(root: root).map(\.event) == [.created, .deleted])
    }

    @Test func aFailedWriteDoesNotBlockLaterWrites() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let notAFolder = home.appendingPathComponent("file")
        try Data("x".utf8).write(to: notAFolder)
        let box = RootBox(notAFolder)
        let recorder = recorder(box, registry: home.appendingPathComponent("external.json"))
        recorder.reconcile()
        await recorder.waitUntilIdle()
        let root = home.appendingPathComponent("Library", isDirectory: true)
        box.root = root
        recorder.recordWritten(markdownURL: try writeLog(root, at: date, text: "one"), kind: .log)
        await recorder.waitUntilIdle()
        #expect(try ChangeLogFile.readEvents(root: root).count == 1)
    }

    @Test func noEnvironmentMeansNoWrites() async throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let recorder = LibraryChangeRecorder()
        recorder.recordWritten(markdownURL: folder.appendingPathComponent("Logs/2026/10/x.md"), kind: .log)
        recorder.recordDeleted([])
        recorder.reconcile()
        await recorder.waitUntilIdle()
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent(".roger").path))
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent(".roger/changes.jsonl").path))
        #expect(try fm.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func changeLogFilesDoNotRescanTheLibrary() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let index = InMemoryLibraryIndex(
            scope: LibraryScanScope(layout: LibraryLayout(root: root), extraFolders: []),
            externalFiles: { [] }
        )
        _ = await index.items()
        for path in [".roger", ".roger/changes.jsonl", ".roger/consumers/crystalline.json", ".roger/consumers/.lock"] {
            #expect(await index.unit(forChangedPath: root.appendingPathComponent(path).path) == nil)
        }
    }
}

struct TrashedItemsTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func logItem(in folder: URL, name: String) throws -> LibraryItem {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".md")
        let entry = LogEntry(text: "x", startedAt: date, endedAt: date, presetName: "Log", language: nil)
        try LogEntryWriter.content(for: entry, audioFileName: name + ".m4a", generatedAt: date).write(to: url, atomically: true, encoding: .utf8)
        try Data().write(to: folder.appendingPathComponent(name + ".m4a"))
        return try #require(LibraryItemReader.item(markdownAt: url, fallbackKind: .log))
    }

    @Test func aLogWithItsAudioIsOneItem() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let item = try logItem(in: root, name: "a")
        let plan = LibraryActions.TrashPlan(urls: [item.url, item.url.deletingPathExtension().appendingPathExtension("m4a")], itemCount: 1)
        #expect(LibraryChangeRecorder.trashedItems([item], plan: plan, failed: []) == [item])
    }

    @Test func failedAndSkippedItemsAreNotDeleted() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let moved = try logItem(in: root, name: "a")
        let failed = try logItem(in: root, name: "b")
        let skipped = try logItem(in: root, name: "c")
        let plan = LibraryActions.TrashPlan(urls: [moved.url, failed.url], itemCount: 2, skipped: [skipped])
        #expect(LibraryChangeRecorder.trashedItems([moved, failed, skipped], plan: plan, failed: [failed.url]) == [moved])
    }

    @Test func aMeetingFolderMapsToItsMeeting() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let folder = root.appendingPathComponent("2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\ntags: [meeting, transcript]\n---\n".utf8).write(to: folder.appendingPathComponent("transcript.md"))
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        let plan = LibraryActions.TrashPlan(urls: [folder], itemCount: 1, meetingFolderCount: 1)
        #expect(LibraryChangeRecorder.trashedItems([item], plan: plan, failed: []) == [item])
    }
}
