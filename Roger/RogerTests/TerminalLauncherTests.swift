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
        let launcher = TerminalLauncher(temporaryDirectory: tmp)
        let url = try launcher.writeScript(commandLine: "true", workingDirectory: tmp)
        #expect(url.lastPathComponent.hasPrefix("roger-command-"))
        #expect(url.pathExtension == "command")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }
}
