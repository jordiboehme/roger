import Foundation
import Testing
@testable import Roger

struct AgentsStatusTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func emptyLibraryIsNotSetUp() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let status = AgentsLibraryStatus.read(root: root)
        #expect(!status.isSetUp)
        #expect(status.eventCount == 0)
        #expect(status.consumers.isEmpty)
    }

    @Test func countsEventsAndOpenEventsPerConsumer() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let changes = (1...3).map { PendingChange(event: .created, kind: .log, key: "Logs/2026/10/\($0)", path: "Logs/2026/10/\($0).md") }
        try await ChangeLog(root: root, now: { [now = self.now] in now }).append(changes)
        try ConsumerBookmarks(root: root).ack("crystalline", upTo: 1, now: now)
        let status = AgentsLibraryStatus.read(root: root)
        #expect(status.isSetUp)
        #expect(status.eventCount == 3)
        #expect(status.lastEventAt == now)
        #expect(status.consumers == [AgentsConsumerRow(name: "crystalline", seq: 1, updatedAt: now, openEvents: 2)])
    }

    @Test func commandsQuoteOnlyWhenNeeded() {
        #expect(McpCommandFormatter.claudeAdd(executable: "/opt/homebrew/bin/roger-mcp")
                == "claude mcp add --scope user roger -- /opt/homebrew/bin/roger-mcp")
        #expect(McpCommandFormatter.claudeAdd(executable: "/Users/x/My Apps/Roger.app/Contents/MacOS/roger-mcp")
                == "claude mcp add --scope user roger -- '/Users/x/My Apps/Roger.app/Contents/MacOS/roger-mcp'")
        #expect(McpCommandFormatter.shellQuoted("/a/it's") == "'/a/it'\\''s'")
    }

    @Test func jsonSnippetHasTheServerEntry() {
        #expect(McpCommandFormatter.jsonSnippet(executable: "/Applications/Roger.app/Contents/MacOS/roger-mcp") == """
        {
          "mcpServers" : {
            "roger" : {
              "args" : [

              ],
              "command" : "/Applications/Roger.app/Contents/MacOS/roger-mcp"
            }
          }
        }
        """)
    }

    private func fakeApp(in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent("Roger.app", isDirectory: true)
        let binary = RogerMCPLocation.bundled(in: app)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        return app
    }

    @Test func bundledPathWithoutAHomebrewLink() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let app = try fakeApp(in: folder)
        #expect(RogerMCPLocation.choose(appBundle: app, links: [folder.appendingPathComponent("bin/roger-mcp").path])
                == .usable(RogerMCPLocation.bundled(in: app).path))
    }

    @Test func homebrewLinkIntoThisBundleWins() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let app = try fakeApp(in: folder)
        let link = folder.appendingPathComponent("bin/roger-mcp")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: RogerMCPLocation.bundled(in: app))
        #expect(RogerMCPLocation.choose(appBundle: app, links: [link.path]) == .usable(link.path))
    }

    @Test func linkIntoAnotherCopyIsIgnored() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let app = try fakeApp(in: folder.appendingPathComponent("A"))
        let other = try fakeApp(in: folder.appendingPathComponent("B"))
        let link = folder.appendingPathComponent("bin/roger-mcp")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: RogerMCPLocation.bundled(in: other))
        #expect(RogerMCPLocation.choose(appBundle: app, links: [link.path]) == .usable(RogerMCPLocation.bundled(in: app).path))
    }

    @Test(arguments: [
        "/private/var/folders/xy/T/AppTranslocation/1234-5678/d/Roger.app",
        "/Volumes/Roger/Roger.app",
    ])
    func translocatedBundleIsRefused(path: String) {
        guard case .unusable(let reason) = RogerMCPLocation.choose(appBundle: URL(fileURLWithPath: path), links: []) else {
            Issue.record("expected unusable")
            return
        }
        #expect(reason.contains("Applications"))
    }
}
