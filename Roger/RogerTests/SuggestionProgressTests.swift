import Foundation
import Testing
@testable import Roger

@MainActor
struct SuggestionProgressTests {
    private static let claudeList = "claude.ai Crystalline: https://example.com/mcp (HTTP) - ✓ Connected\n"

    private static func makeCLI(_ name: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func finder(home: URL, runner: FakeRunner, path: [String], fromShell: Bool = true) -> CommandSuggestionFinder {
        CommandSuggestionFinder(home: home, runner: runner) {
            CommandSearchPathLookup(path: path, codexHome: nil, fromShell: fromShell)
        }
    }

    private static func titles(_ progress: SuggestionProgress) -> [String] {
        progress.steps.map(\.title)
    }

    @Test func plannedStepsBeforeTheSearch() {
        let progress = SuggestionProgress()
        #expect(Self.titles(progress) == [
            "Read the search path from your login shell",
            "Look for coding agents",
            "Prepare the suggestions",
        ])
        #expect(progress.steps.allSatisfy { $0.state == .waiting })
    }

    @Test func oneAgentAddsItsSettingsLine() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let bin = home.appendingPathComponent("bin")
        try Self.makeCLI("codex", in: bin)
        let runner = FakeRunner([])
        let progress = SuggestionProgress()

        let suggestions = await Self.finder(home: home, runner: runner, path: [bin.path]).run(progress: progress)

        #expect(Self.titles(progress) == [
            "Read the search path from your login shell",
            "Look for coding agents",
            "Read the Codex settings",
            "Prepare the suggestions",
        ])
        #expect(progress.steps.allSatisfy { $0.state == .done })
        #expect(progress.step(.findAgents)?.detail == "Codex")
        #expect(!suggestions.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    /// Settings reads first, then the slow `claude mcp list`, then the list.
    @Test func twoAgentsWithClaudeCode() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let bin = home.appendingPathComponent("bin")
        try Self.makeCLI("claude", in: bin)
        try Self.makeCLI("codex", in: bin)
        try Data(#"{"mcpServers":{"roger":{"command":"/x/roger-mcp"}}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let runner = FakeRunner([CommandResult(status: .exited(0), stdout: Self.claudeList, stderr: "")])
        let progress = SuggestionProgress()

        let suggestions = await Self.finder(home: home, runner: runner, path: [bin.path]).run(progress: progress)

        #expect(Self.titles(progress) == [
            "Read the search path from your login shell",
            "Look for coding agents",
            "Read the Claude Code settings",
            "Read the Codex settings",
            "Ask Claude Code for its servers",
            "Prepare the suggestions",
        ])
        #expect(progress.steps.allSatisfy { $0.state == .done })
        #expect(progress.step(.findAgents)?.detail == "Claude Code and Codex")
        #expect(runner.calls == [["claude", "mcp", "list"]])
        #expect(suggestions.contains { $0.usesCrystalline })
    }

    @Test func shellFailureFallsBackToTheStandardFolders() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let progress = SuggestionProgress()

        _ = await Self.finder(home: home, runner: FakeRunner([]), path: [home.path], fromShell: false).run(progress: progress)

        #expect(progress.step(.searchPath)?.state == .warning("Shell did not answer - using the standard folders"))
        #expect(progress.step(.findAgents)?.state == .done)
        #expect(progress.step(.prepare)?.state == .done)
    }

    @Test func claudeTimeoutFallsBackToItsSettingsFile() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        try Self.makeCLI("claude", in: home)
        try Data(#"{"mcpServers":{"roger":{"command":"/x/roger-mcp"}}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let runner = FakeRunner([CommandResult(status: .timedOut, stdout: "", stderr: "")])
        let progress = SuggestionProgress()

        let suggestions = await Self.finder(home: home, runner: runner, path: [home.path]).run(progress: progress)

        #expect(progress.step(.askClaude)?.state == .warning("Claude Code did not answer in 20 s - using its settings file"))
        #expect(progress.step(.prepare)?.state == .done)
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.disabledReason == nil })
    }

    @Test func claudeFailureFallsBackToItsSettingsFile() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        try Self.makeCLI("claude", in: home)
        try Data(#"{"mcpServers":{"roger":{"command":"/x/roger-mcp"}}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let runner = FakeRunner([CommandResult(status: .exited(1), stdout: "", stderr: "not logged in")])
        let progress = SuggestionProgress()

        let suggestions = await Self.finder(home: home, runner: runner, path: [home.path]).run(progress: progress)

        #expect(progress.step(.askClaude)?.state == .warning("Claude Code did not answer - using its settings file"))
        #expect(suggestions.allSatisfy { $0.disabledReason == nil })
    }

    @Test func noAgentsFound() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let progress = SuggestionProgress()

        let suggestions = await Self.finder(home: home, runner: FakeRunner([]), path: [home.path]).run(progress: progress)

        #expect(suggestions.isEmpty)
        #expect(progress.step(.findAgents)?.detail == "None")
        #expect(Self.titles(progress).count == 3)
        #expect(progress.steps.allSatisfy { $0.state == .done })
    }

    // MARK: - Folders

    @Test func findReportsEachFolderInOrderAndTheFirstOneWins() throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let first = home.appendingPathComponent("a")
        let second = home.appendingPathComponent("b")
        let empty = home.appendingPathComponent("c").path
        try Self.makeCLI("claude", in: first)
        try Self.makeCLI("claude", in: second)
        try Self.makeCLI("codex", in: second)
        var seen: [String] = []

        let found = HarnessServerDetector(home: home, runner: FakeRunner([]), searchPath: [empty, first.path, second.path])
            .findCLIs { seen.append($0) }

        #expect(seen == [empty, first.path, second.path])
        #expect(found.map(\.0.id) == [.claudeCode, .codex])
        #expect(found[0].1.deletingLastPathComponent().lastPathComponent == "a")
    }

    @Test func lateFolderUpdatesAreDropped() {
        let progress = SuggestionProgress()
        progress.start(.findAgents)
        progress.checking("/new", sequence: 2)
        progress.checking("/old", sequence: 1)
        #expect(progress.step(.findAgents)?.checking == "/new")
        progress.finish(.findAgents, detail: "None")
        progress.checking("/later", sequence: 3)
        #expect(progress.step(.findAgents)?.checking == nil)
    }

    // MARK: - Search path cache

    @Test func shellPathIsCachedOnceItAnswered() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let output = "\(CLILocator.pathMarker)/custom/bin\(CLILocator.pathMarker)\(CLILocator.codexHomeMarker)/ch\(CLILocator.codexHomeMarker)"
        let runner = FakeRunner([CommandResult(status: .exited(0), stdout: output, stderr: "")])
        let cache = CommandSearchPathCache()

        let first = await cache.lookup(runner: runner, home: home)
        let second = await cache.lookup(runner: runner, home: home)

        #expect(first.fromShell)
        #expect(first.path.first == "/custom/bin")
        #expect(first.codexHome == "/ch")
        #expect(second == first)
        #expect(runner.calls.count == 1)
    }

    @Test func failedShellIsAskedAgain() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let runner = FakeRunner([CommandResult(status: .timedOut, stdout: "", stderr: "")])
        let cache = CommandSearchPathCache()

        let first = await cache.lookup(runner: runner, home: home)
        _ = await cache.lookup(runner: runner, home: home)

        #expect(!first.fromShell)
        #expect(first.path == CLILocator.searchPath(loginShellPATH: nil, home: home))
        #expect(runner.calls.count == 2)
    }
}
