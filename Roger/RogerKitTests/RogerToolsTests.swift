import Foundation
import Testing
@testable import RogerKit

/// Preferences that a test can change between calls, like Roger's settings.
final class PreferencesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RogerPreferences
    init(_ value: RogerPreferences) { self.value = value }
    func get() -> RogerPreferences { lock.withLock { value } }
    func set(_ newValue: RogerPreferences) { lock.withLock { value = newValue } }
}

struct RogerToolsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func tools(_ root: URL) -> RogerTools {
        let now = self.now
        return RogerTools(
            locator: LibraryLocator(argument: root.path, preferences: { RogerPreferences(libraryRoot: nil, extraScanFolders: []) }),
            registry: ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("none.json")),
            now: { now }
        )
    }

    /// Two logs and a meeting, caught up into the change log (seq 1 to 3).
    private func library() async throws -> URL {
        let root = try TempDir.make()
        let layout = LibraryLayout(root: root)
        try KitFixtures.log(in: layout, at: KitFixtures.base, text: "Called the supplier", audio: true)
        try KitFixtures.log(in: layout, at: KitFixtures.base.addingTimeInterval(60), text: "Invoice arrived")
        try KitFixtures.meeting(in: layout.monthFolder(.meetings, for: KitFixtures.base), name: "2026-09-21 16-00",
                                at: KitFixtures.base.addingTimeInterval(120), text: "Supplier meeting", screenshot: true)
        let items = LibraryScanner.scanAll(scope: LibraryScanScope(layout: layout, extraFolders: []), externalFiles: [])
        try await ChangeLog(root: root).reconcile(items: items)
        return root
    }

    @Test func statusBeforeSetUp() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let status = tools(root).call("status", arguments: [:])
        #expect(!status.isError)
        #expect(status.text.contains("Start Roger once to set up the library"))
        let changes = tools(root).call("get_changes", arguments: ["consumer": .string("crystalline")])
        #expect(changes.isError)
        #expect(changes.text.contains("Start Roger once to set up the library"))
    }

    @Test func statusReportsCountsAndConsumers() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        _ = tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(1)])
        let text = tools(root).call("status", arguments: [:]).text
        #expect(text.contains("state: ready"))
        #expect(text.contains("lastSeq: 3"))
        #expect(text.contains("items:\n  log: 2\n  meeting: 1\n  transcript: 0"))
        #expect(text.contains("consumers[1]{name,seq,updatedAt,age,open}:\n  crystalline,1,"))
        #expect(text.hasSuffix(",0m,2"))
    }

    @Test(arguments: [
        [String: ToolValue](),
        ["consumer": .string("crystalline"), "since": .int(1)],
        ["consumer": .string("crystalline"), "from": .int(1), "upTo": .int(2)],
        ["from": .int(1)],
        ["upTo": .int(2)],
    ])
    func getChangesNeedsExactlyOneStart(arguments: [String: ToolValue]) async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let output = tools(root).call("get_changes", arguments: arguments)
        #expect(output.isError)
        #expect(output.text.contains("exactly one start") || output.text.contains("together"))
    }

    @Test func consumerLoopEndsEmpty() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let first = tools(root).call("get_changes", arguments: ["consumer": .string("crystalline")])
        #expect(!first.isError)
        #expect(first.text.hasPrefix("from: 1\nupTo: 3\nmore: false\ncount: 3"))
        let ack = tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(3)])
        #expect(ack.text == "Bookmark crystalline is now 3 (was 0).")
        let again = tools(root).call("get_changes", arguments: ["consumer": .string("crystalline")])
        #expect(again.text == "from: 4\nupTo: 3\nmore: false\ncount: 0")
    }

    @Test func sinceTakesNumbersAsIntegersOrStrings() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        for value in [ToolValue.int(2), .string("2"), .double(2)] {
            let text = tools(root).call("get_changes", arguments: ["since": value]).text
            #expect(text.hasPrefix("from: 3\nupTo: 3\nmore: false\ncount: 1"))
        }
        let bad = tools(root).call("get_changes", arguments: ["since": .string("last tuesday")])
        #expect(bad.isError)
        #expect(bad.text.contains("30m, 12h or 3d"))
    }

    @Test func rangeMustBeInsideTheLog() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        #expect(tools(root).call("get_changes", arguments: ["from": .int(2), "upTo": .int(9)]).isError)
        #expect(tools(root).call("get_changes", arguments: ["from": .int(0), "upTo": .int(2)]).isError)
        #expect(tools(root).call("get_changes", arguments: ["from": .int(3), "upTo": .int(2)]).isError)
        let ok = tools(root).call("get_changes", arguments: ["from": .int(2), "upTo": .int(3), "summary": .bool(true)])
        #expect(ok.text.hasPrefix("from: 2\nupTo: 3\nmore: false\ncount: 2"))
    }

    @Test func kindsAreChecked() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let bad = tools(root).call("get_changes", arguments: ["consumer": .string("x"), "kinds": .array([.string("log"), .string("podcast")])])
        #expect(bad.isError)
        let meetings = tools(root).call("get_changes", arguments: ["consumer": .string("x"), "kinds": .array([.string("meeting")])])
        #expect(meetings.text.contains("count: 1"))
        #expect(meetings.text.contains("kind: meeting"))
    }

    @Test func ackRules() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        #expect(tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(4)]).isError)
        #expect(tools(root).call("ack", arguments: ["consumer": .string("Crystalline"), "upTo": .int(1)]).text.contains("not a valid consumer name"))
        _ = tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(3)])
        let older = tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(1)])
        #expect(!older.isError)
        #expect(older.text == "Bookmark crystalline stays at 3. upTo 1 is not newer.")
    }

    @Test func getItemReturnsMarkdownThenPaths() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let key = try #require(ChangeLogFile.readEvents(root: root).first { $0.kind == .meeting }?.key)
        let output = tools(root).call("get_item", arguments: ["key": .string(key)])
        #expect(!output.isError)
        #expect(output.text.hasPrefix("---\ntype: source"))
        #expect(output.text.contains("\n\n==== roger paths ====\npaths[3]: /"))
    }

    /// A transcript in an extra scan folder inside the root: list_items
    /// gives a key that get_item opens.
    @Test func itemInAnotherFolderOfTheRootOpensByItsKey() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try KitFixtures.transcript(at: inbox.appendingPathComponent("talk.m4a.md"), at: KitFixtures.base, title: "Talk", text: "Quarterly numbers")
        let layout = LibraryLayout(root: root)
        let items = LibraryScanner.scanAll(scope: LibraryScanScope(layout: layout, extraFolders: [inbox]), externalFiles: [])
        try await ChangeLog(root: root).reconcile(items: items)
        let now = self.now
        let tools = RogerTools(
            locator: LibraryLocator(argument: nil, preferences: { RogerPreferences(libraryRoot: root.path, extraScanFolders: [inbox.path]) }),
            registry: ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("none.json")),
            now: { now }
        )
        let list = tools.call("list_items", arguments: [:]).text
        #expect(list.hasPrefix("items[1]{key,kind,title,date,duration,paths}:\n  External/talk.m4a-"))
        let key = try #require(list.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces).split(separator: ",").first.map(String.init))
        let item = tools.call("get_item", arguments: ["key": .string(key)])
        #expect(!item.isError)
        #expect(item.text.contains("Quarterly numbers"))
    }

    @Test(arguments: ["../x", "/etc/passwd", "Logs/../../etc/passwd", "~/secret"])
    func getItemRejectsPaths(key: String) async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let output = tools(root).call("get_item", arguments: ["key": .string(key)])
        #expect(output.isError)
        #expect(output.text.contains("not a valid key"))
    }

    @Test func listItemsHonorsKindSinceAndLimit() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let all = tools(root).call("list_items", arguments: [:]).text
        #expect(all.hasPrefix("items[3]{key,kind,title,date,duration,paths}:\n  Meetings/"))
        #expect(tools(root).call("list_items", arguments: ["limit": .int(1)]).text.hasPrefix("items[1]"))
        #expect(tools(root).call("list_items", arguments: ["kind": .string("log")]).text.hasPrefix("items[2]"))
        #expect(!tools(root).call("list_items", arguments: ["limit": .int(9_999)]).isError)
        #expect(tools(root).call("list_items", arguments: ["limit": .int(0)]).isError)
        #expect(tools(root).call("list_items", arguments: ["since": .int(3)]).isError)
        let since = RFC3339.string(KitFixtures.base.addingTimeInterval(90))
        #expect(tools(root).call("list_items", arguments: ["since": .string(since)]).text.hasPrefix("items[1]"))
        #expect(all.contains(" | "))
    }

    @Test func searchNeedsAQuery() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        #expect(tools(root).call("search", arguments: [:]).isError)
        let found = tools(root).call("search", arguments: ["query": .string("supplier")]).text
        #expect(found.hasPrefix("results[2]{key,kind,title,date,snippet}:"))
        #expect(tools(root).call("search", arguments: ["query": .string("zebra")]).text == "results: []")
    }

    @Test func unknownToolIsAnError() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        #expect(tools(root).call("delete_everything", arguments: [:]) == .error("Unknown tool \"delete_everything\"."))
    }

    @Test func followsALibraryRootChangeWithoutRestart() async throws {
        let a = try await library()
        let b = try await library()
        defer {
            TempDir.remove(a)
            TempDir.remove(b)
        }
        let box = PreferencesBox(RogerPreferences(libraryRoot: a.path, extraScanFolders: []))
        let tools = RogerTools(
            locator: LibraryLocator(argument: nil, preferences: { box.get() }),
            registry: ExternalTranscriptRegistry(fileURL: a.appendingPathComponent("none.json"))
        )
        #expect(tools.call("status", arguments: [:]).text.hasPrefix("library: \(a.path)\n"))
        _ = tools.call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(3)])
        box.set(RogerPreferences(libraryRoot: b.path, extraScanFolders: []))
        #expect(tools.call("status", arguments: [:]).text.hasPrefix("library: \(b.path)\n"))
        // The bookmark belongs to library A; in B the consumer starts over.
        #expect(tools.call("get_changes", arguments: ["consumer": .string("crystalline"), "summary": .bool(true)]).text.contains("count: 3"))
    }

    @Test func deniedAccessExplainsFilesAndFolders() async throws {
        let root = try await library()
        let roger = ChangeLogFile.folder(root: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roger.path)
            TempDir.remove(root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: roger.path)
        let status = tools(root).call("status", arguments: [:]).text
        #expect(status.contains("Files and Folders"))
        #expect(!status.contains("Start Roger once"))
        for name in ["get_changes", "ack", "get_item", "list_items", "search"] {
            let output = tools(root).call(name, arguments: ["consumer": .string("x"), "upTo": .int(1), "key": .string("Logs/x"), "query": .string("x")])
            #expect(output.isError)
            #expect(output.text.contains("Files and Folders"))
        }
    }

    @Test func onlyBookmarksAreWritten() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        func snapshot() throws -> [String: Date] {
            var result: [String: Date] = [:]
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
            while let url = enumerator?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: keys)
                // Folders change when consumers/ appears; only files count.
                guard values.isRegularFile == true, !url.path.contains("/.roger/consumers/") else { continue }
                result[url.path] = values.contentModificationDate
            }
            return result
        }
        let before = try snapshot()
        let key = try #require(ChangeLogFile.readEvents(root: root).first?.key)
        for (name, arguments) in [
            ("status", [String: ToolValue]()),
            ("get_changes", ["consumer": .string("crystalline")]),
            ("ack", ["consumer": .string("crystalline"), "upTo": .int(3)]),
            ("get_item", ["key": .string(key)]),
            ("list_items", [:]),
            ("search", ["query": .string("supplier")]),
        ] {
            #expect(!tools(root).call(name, arguments: arguments).isError)
        }
        #expect(try snapshot() == before)
    }
}
