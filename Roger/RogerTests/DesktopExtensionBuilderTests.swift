import AppKit
import Foundation
import Testing
@testable import Roger

struct DesktopExtensionBuilderTests {
    private let exe = "/Applications/Roger.app/Contents/MacOS/roger-mcp"

    private func zipEntries(_ zip: URL) throws -> [String] {
        try run("/usr/bin/zipinfo", ["-1", zip.path]).split(separator: "\n").map(String.init).sorted()
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func pngIcon() throws -> Data {
        try #require(DesktopExtensionBuilder.iconPNG(for: Bundle.main.bundleURL))
    }

    @Test func manifestFollowsMCPB() throws {
        let data = try JSONEncoder().encode(DesktopExtensionBuilder.manifest(executable: exe, version: "0.25.0"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["manifest_version"] as? String == "0.3")
        #expect(json["name"] as? String == "roger")
        #expect(json["version"] as? String == "0.25.0")
        #expect(json["icon"] as? String == "icon.png")
        #expect((json["author"] as? [String: Any])?["name"] as? String == "Jordi Böhme")
        let server = try #require(json["server"] as? [String: Any])
        #expect(server["type"] as? String == "binary")
        #expect(server["entry_point"] as? String == "server/roger-mcp")
        let config = try #require(server["mcp_config"] as? [String: Any])
        #expect(config["command"] as? String == exe)
        #expect((config["args"] as? [String])?.isEmpty == true)
        #expect((json["compatibility"] as? [String: Any])?["platforms"] as? [String] == ["darwin"])
        #expect((json["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.sorted() == ["ack", "get_changes", "get_item", "list_items", "search", "status"])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"))
    }

    @Test func launcherExecsTheQuotedPath() {
        #expect(DesktopExtensionBuilder.launcher(executable: "/Users/x/My Apps/Roger.app/Contents/MacOS/roger-mcp")
                == "#!/bin/sh\nexec '/Users/x/My Apps/Roger.app/Contents/MacOS/roger-mcp' \"$@\"\n")
    }

    @Test func extensionZipHasTheBundleLayout() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let mcpb = try DesktopExtensionBuilder.buildExtension(executable: exe, version: "0.25.0", iconPNG: pngIcon(), in: folder, archiver: DittoArchiver())
        #expect(mcpb.lastPathComponent == "roger.mcpb")
        #expect(try zipEntries(mcpb) == ["icon.png", "manifest.json", "server/", "server/roger-mcp"])
        let listing = try run("/usr/bin/zipinfo", [mcpb.path, "server/roger-mcp"])
        #expect(listing.hasPrefix("-rwxr-xr-x"))
        let iconProcess = Process()
        iconProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        iconProcess.arguments = ["-p", mcpb.path, "icon.png"]
        let iconPipe = Pipe()
        iconProcess.standardOutput = iconPipe
        try iconProcess.run()
        let iconData = iconPipe.fileHandleForReading.readDataToEndOfFile()
        iconProcess.waitUntilExit()
        #expect(Array(iconData.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        // Building again replaces Roger's own temp bundle.
        _ = try DesktopExtensionBuilder.buildExtension(executable: exe, version: "0.25.1", iconPNG: pngIcon(), in: folder, archiver: DittoArchiver())
        #expect(try run("/usr/bin/unzip", ["-p", mcpb.path, "manifest.json"]).contains("0.25.1"))
    }

    @Test func skillZipHoldsTheSkillFolder() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let zip = try DesktopExtensionBuilder.buildSkillZip(skill, in: folder, archiver: DittoArchiver())
        #expect(zip.lastPathComponent == "ingest-roger.zip")
        #expect(try zipEntries(zip) == ["ingest-roger/", "ingest-roger/SKILL.md"])
        #expect(try run("/usr/bin/unzip", ["-p", zip.path, "ingest-roger/SKILL.md"]) == "---\nname: ingest-roger\n---\n")
        // A second save never overwrites the first file in Downloads.
        let second = try DesktopExtensionBuilder.buildSkillZip(skill, in: folder, archiver: DittoArchiver())
        #expect(second.lastPathComponent == "ingest-roger 1.zip")
    }

    @Test func movedAppShowsWarning() {
        var record = DesktopRecord()
        #expect(!record.appMoved(currentExecutable: exe))
        record.extensionCommand = exe
        #expect(!record.appMoved(currentExecutable: exe))
        #expect(record.appMoved(currentExecutable: "/Users/x/Applications/Roger.app/Contents/MacOS/roger-mcp"))
    }

    @Test func recordRoundTrips() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let store = DesktopRecordStore(fileURL: folder.appendingPathComponent("claude-desktop.json"))
        #expect(store.load() == DesktopRecord())
        let record = DesktopRecord(extensionCommand: exe, extensionAddedAt: Date(timeIntervalSince1970: 1_790_000_000), skillSavedAt: nil)
        try store.save(record)
        #expect(store.load() == record)
    }
}
