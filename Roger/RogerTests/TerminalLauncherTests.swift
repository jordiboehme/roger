import Foundation
import Testing
@testable import Roger

struct TerminalLauncherTests {
    @Test func scriptCdsDeletesItselfAndRuns() {
        let s = TerminalLauncher.scriptContent(commandLine: "claude 'hi'", workingDirectory: URL(fileURLWithPath: "/Users/a/my dir"))
        #expect(s == "#!/bin/zsh -l\ncd '/Users/a/my dir' || exit 1\nrm -f \"$0\"\nclaude 'hi'\n")
    }

    @Test func scriptQuotesDirectoryWithQuote() {
        let s = TerminalLauncher.scriptContent(commandLine: "x", workingDirectory: URL(fileURLWithPath: "/tmp/it's"))
        #expect(s.contains("cd '/tmp/it'\\''s' || exit 1"))
    }

    @Test func writtenScriptIsExecutableByOwnerOnly() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roger-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let launcher = TerminalLauncher(temporaryDirectory: tmp)
        let url = try launcher.writeScript(commandLine: "true", workingDirectory: tmp)
        #expect(url.lastPathComponent.hasPrefix("roger-command-"))
        #expect(url.pathExtension == "command")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        #expect(try String(contentsOf: url, encoding: .utf8) == TerminalLauncher.scriptContent(commandLine: "true", workingDirectory: tmp))
    }

    @Test func warpYAMLQuotesPaths() {
        let yaml = TerminalLauncher.warpYAML(
            name: "roger-command-1",
            workingDirectory: URL(fileURLWithPath: "/Users/a/my \"dir\\x"),
            script: URL(fileURLWithPath: "/tmp/a b/roger-command-1.command")
        )
        #expect(yaml == """
        ---
        name: roger-command-1
        windows:
          - tabs:
              - layout:
                  cwd: "/Users/a/my \\"dir\\\\x"
                  commands:
                    - exec: "'/tmp/a b/roger-command-1.command'"

        """)
    }

    @Test func staleWarpConfigsAreRemoved() throws {
        let dir = try TempFolder.make()
        defer { TempFolder.remove(dir) }
        let fm = FileManager.default
        let now = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let old = try file("roger-command-old.yaml", age: 120)
        let fresh = try file("roger-command-new.yaml", age: 10)
        let other = try file("my-layout.yaml", age: 3600)
        TerminalLauncher.removeStaleWarpConfigs(in: dir, now: now)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: other.path))
    }
}
