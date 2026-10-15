import Foundation
import Testing
@testable import Roger

struct CommandSuggestionsTests {
    private let rogerOnly = HarnessServers(rogerToolPrefix: "mcp__roger", crystallineToolPrefix: nil)
    private let withConnector = HarnessServers(rogerToolPrefix: "mcp__roger", crystallineToolPrefix: "mcp__claude_ai_Crystalline", crystallineServerName: "claude.ai Crystalline")
    private let withServer = HarnessServers(rogerToolPrefix: "mcp__roger", crystallineToolPrefix: "mcp__crystalline", crystallineServerName: "crystalline")
    private let noRoger = HarnessServers(rogerToolPrefix: nil, crystallineToolPrefix: nil)

    // MARK: - Command lines

    /// `--allowedTools` takes a list, so without `--` it would eat the prompt
    /// ("Input must be provided ..." with claude 2026-10).
    @Test func claudeHeadlessAllowsRoger() {
        #expect(CommandSuggestions.commandLine(for: .claudeCode, mode: .headless, servers: rogerOnly)
            == "claude -p --allowedTools 'mcp__roger' -- {prompt}")
    }

    @Test func claudeHeadlessAllowsRogerAndCrystalline() {
        #expect(CommandSuggestions.commandLine(for: .claudeCode, mode: .headless, servers: withConnector)
            == "claude -p --allowedTools 'mcp__roger,mcp__claude_ai_Crystalline' -- {prompt}")
    }

    @Test func claudeInteractive() {
        #expect(CommandSuggestions.commandLine(for: .claudeCode, mode: .interactive, servers: withConnector) == "claude {prompt}")
    }

    @Test func codexApprovesTheServersInExec() {
        #expect(CommandSuggestions.commandLine(for: .codex, mode: .headless, servers: rogerOnly)
            == "codex exec --skip-git-repo-check -c 'mcp_servers.roger.default_tools_approval_mode=\"approve\"' {prompt}")
        #expect(CommandSuggestions.commandLine(for: .codex, mode: .headless, servers: withServer)
            == "codex exec --skip-git-repo-check -c 'mcp_servers.roger.default_tools_approval_mode=\"approve\"' -c 'mcp_servers.crystalline.default_tools_approval_mode=\"approve\"' {prompt}")
        #expect(CommandSuggestions.commandLine(for: .codex, mode: .interactive, servers: rogerOnly) == "codex {prompt}")
    }

    @Test func copilotAllowsTheServers() {
        #expect(CommandSuggestions.commandLine(for: .copilot, mode: .headless, servers: withServer)
            == "copilot -p {prompt} --allow-tool='roger' --allow-tool='crystalline'")
        #expect(CommandSuggestions.commandLine(for: .copilot, mode: .interactive, servers: rogerOnly) == "copilot -i {prompt}")
    }

    @Test func geminiAndKiroOnlyInATerminal() {
        #expect(CommandSuggestions.commandLine(for: .gemini, mode: .headless, servers: rogerOnly) == nil)
        #expect(CommandSuggestions.commandLine(for: .gemini, mode: .interactive, servers: rogerOnly) == "gemini -i {prompt}")
        #expect(CommandSuggestions.commandLine(for: .kiro, mode: .headless, servers: rogerOnly) == nil)
        #expect(CommandSuggestions.commandLine(for: .kiro, mode: .interactive, servers: rogerOnly) == "kiro-cli chat {prompt}")
    }

    @Test func cursorIsNeverOffered() {
        for mode in CommandMode.allCases {
            #expect(CommandSuggestions.commandLine(for: .cursor, mode: mode, servers: rogerOnly) == nil)
        }
        #expect(CommandSuggestions.suggestions(for: [(.cursor, rogerOnly)]).isEmpty)
    }

    // MARK: - Prompts

    @Test func promptTexts() {
        #expect(CommandSuggestions.crystallineHeadlessPrompt == "Use the ingest-roger skill to read what is new in Roger. Fold it into Crystalline with the ingestion method of crystalline-capture. Choose the domains by their routing. Keep tasks as [task] observations in the engrams they belong to. At the end, list the tasks you found.")
        #expect(CommandSuggestions.crystallineInteractivePrompt == "Use the ingest-roger skill to read what is new in Roger. Fold it into Crystalline with the ingestion method of crystalline-capture. Choose the domains by their routing. Keep tasks as [task] observations in the engrams they belong to. At the end, list the tasks you found and ask me which ones to work on.")
        #expect(!CommandSuggestions.crystallineHeadlessPrompt.contains("/ingest-roger"))
    }

    @Test func crystallinePromptOnlyWithCrystalline() throws {
        let with = CommandSuggestions.suggestions(for: [(.claudeCode, withConnector)])
        #expect(with.map(\.command.prompt) == [CommandSuggestions.crystallineHeadlessPrompt, CommandSuggestions.crystallineInteractivePrompt])
        let allUse = with.allSatisfy { $0.usesCrystalline }
        #expect(allUse)
        let without = CommandSuggestions.suggestions(for: [(.claudeCode, rogerOnly)])
        #expect(without.map(\.command.prompt) == [CommandSuggestions.plainHeadlessPrompt, CommandSuggestions.plainInteractivePrompt])
        let anyUses = without.contains { $0.usesCrystalline }
        #expect(!anyUses)
    }

    // MARK: - Suggestions

    @Test func suggestionFields() throws {
        let list = CommandSuggestions.suggestions(for: [(.claudeCode, rogerOnly)])
        #expect(list.map(\.id) == ["claudeCode-headless", "claudeCode-interactive"])
        #expect(list.map(\.title) == ["Claude Code, in the background", "Claude Code, in a terminal window"])
        let headless = try #require(list.first)
        #expect(headless.disabledReason == nil)
        #expect(headless.command.name == "Claude Code ingest")
        #expect(headless.command.mode == .headless)
        #expect(headless.command.workingDirectory == "~")
        #expect(headless.command.commandLine == "claude -p --allowedTools 'mcp__roger' -- {prompt}")
        #expect(list[1].command.name == "Claude Code ingest (terminal)")
        #expect(list[1].command.mode == .interactive)
        #expect(list[1].command.workingDirectory == "~")
    }

    @Test func freshIDsOnEachBuild() {
        let a = CommandSuggestions.suggestions(for: [(.claudeCode, rogerOnly)])
        let b = CommandSuggestions.suggestions(for: [(.claudeCode, rogerOnly)])
        #expect(a[0].command.id != b[0].command.id)
    }

    @Test func disabledWithoutRoger() {
        let list = CommandSuggestions.suggestions(for: [(.claudeCode, noRoger)])
        #expect(list.count == 2)
        let allDisabled = list.allSatisfy { $0.disabledReason == "Roger not connected, see Agents" }
        #expect(allDisabled)
    }

    @Test func orderedByCatalogBackgroundFirst() {
        let list = CommandSuggestions.suggestions(for: [(.kiro, rogerOnly), (.copilot, rogerOnly), (.gemini, rogerOnly), (.codex, rogerOnly), (.claudeCode, rogerOnly)])
        #expect(list.map(\.id) == [
            "claudeCode-headless", "claudeCode-interactive",
            "codex-headless", "codex-interactive",
            "gemini-interactive",
            "copilot-headless", "copilot-interactive",
            "kiro-interactive",
        ])
    }

    // MARK: - Servers

    @Test func serversFromConfiguredNames() {
        let servers = HarnessServers(configured: [
            ConfiguredServer(name: "roger", command: "/x/roger-mcp"),
            ConfiguredServer(name: "Crystalline", command: nil),
        ])
        #expect(servers == HarnessServers(rogerToolPrefix: "mcp__roger", crystallineToolPrefix: "mcp__Crystalline", crystallineServerName: "Crystalline"))
    }

    @Test func crystallineByCommandBasename() {
        let servers = HarnessServers(configured: [ConfiguredServer(name: "memory", command: "/opt/homebrew/bin/crystalline")])
        #expect(servers.rogerToolPrefix == nil)
        #expect(servers.crystallineToolPrefix == "mcp__memory")
        #expect(servers.crystallineServerName == "memory")
        #expect(HarnessServers(configured: [ConfiguredServer(name: "x", command: "/bin/crystalline-old")]).crystallineToolPrefix == nil)
    }

    @Test func claudeAIConnectorPrefix() {
        #expect(HarnessServers.toolPrefix(serverName: "claude.ai Crystalline") == "mcp__claude_ai_Crystalline")
        #expect(HarnessServers.toolPrefix(serverName: "claude.ai Google Drive") == "mcp__claude_ai_Google_Drive")
        #expect(HarnessServers.toolPrefix(serverName: "roger") == "mcp__roger")
    }

    /// `claude mcp list` from 2026-10-15, URLs and the user path replaced.
    static let claudeMcpListFixture = """
    Checking MCP server health…

    claude.ai Claude Docs: https://example.invalid/mcp - ✔ Connected
    claude.ai Crystalline: https://example.invalid/mcp - ✔ Connected
    claude.ai Google Drive: https://example.invalid/mcp - ✔ Connected
    private-mcp: https://example.invalid/mcp (HTTP) - ✔ Connected
    context7: https://example.invalid/mcp (HTTP) - ✔ Connected
    home: https://example.invalid/mcp (HTTP) - ! Needs authentication
    roger: /Applications/Roger App/Roger.app/Contents/MacOS/roger-mcp  - ✔ Connected
    local: /Users/someone/bin/crystalline serve - ✗ Failed to connect
    """

    @Test func parsesClaudeMcpList() {
        let servers = ClaudeMcpList.parse(Self.claudeMcpListFixture)
        #expect(servers.map(\.name) == ["claude.ai Claude Docs", "claude.ai Crystalline", "claude.ai Google Drive", "private-mcp", "context7", "home", "roger", "local"])
        #expect(servers[6].command == "/Applications/Roger App/Roger.app/Contents/MacOS/roger-mcp")
        #expect(servers[3].command == "https://example.invalid/mcp")
        #expect(servers[7].command == "/Users/someone/bin/crystalline serve")
        let merged = HarnessServers(configured: servers)
        #expect(merged.rogerToolPrefix == "mcp__roger")
        // The first Crystalline wins: the claude.ai connector.
        #expect(merged.crystallineToolPrefix == "mcp__claude_ai_Crystalline")
    }

    @Test func emptyClaudeMcpList() {
        #expect(ClaudeMcpList.parse("No MCP servers configured. Use `claude mcp add` to add a server.\n").isEmpty)
    }

    // MARK: - Detection

    @Test func detectsInstalledHarnessesAndTheirServers() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for cli in ["claude", "codex"] {
            let url = bin.appendingPathComponent(cli)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try Data(#"{"mcpServers":{"roger":{"command":"/x/roger-mcp"}}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("[mcp_servers.roger]\ncommand = \"/x/roger-mcp\"\n\n[mcp_servers.mem]\ncommand = \"/usr/local/bin/crystalline\"\n".utf8)
            .write(to: home.appendingPathComponent(".codex/config.toml"))
        let runner = FakeRunner([CommandResult(status: .exited(0), stdout: Self.claudeMcpListFixture, stderr: "")])

        let found = await HarnessServerDetector(home: home, runner: runner, searchPath: [bin.path]).detect()

        #expect(found.map(\.0) == [.claudeCode, .codex])
        #expect(found[0].1.crystallineToolPrefix == "mcp__claude_ai_Crystalline")
        #expect(found[0].1.rogerToolPrefix == "mcp__roger")
        #expect(found[1].1 == HarnessServers(rogerToolPrefix: "mcp__roger", crystallineToolPrefix: "mcp__mem", crystallineServerName: "mem"))
        #expect(runner.calls == [["claude", "mcp", "list"]])
    }

    @Test func claudeTimeoutFallsBackToTheConfig() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let url = home.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try Data(#"{"mcpServers":{"roger":{"command":"/x/roger-mcp"}}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let runner = FakeRunner([CommandResult(status: .timedOut, stdout: "", stderr: "")])

        let found = await HarnessServerDetector(home: home, runner: runner, searchPath: [home.path]).detect()

        #expect(found.count == 1)
        #expect(found[0].1 == HarnessServers(rogerToolPrefix: "mcp__roger", crystallineToolPrefix: nil))
    }
}

struct HarnessServerLookupTests {
    @Test func jsonCommandForAnyServer() {
        let data = Data(#"{"mcpServers":{"roger":{"command":"/r"},"crystalline":{"command":"/c"}}}"#.utf8)
        #expect(HarnessRegistration.jsonCommand(data) == .command("/r"))
        #expect(HarnessRegistration.jsonCommand(data, server: "crystalline") == .command("/c"))
        #expect(HarnessRegistration.jsonCommand(data, server: "other") == .absent)
    }

    @Test func tomlCommandForAnyServer() {
        let text = "[mcp_servers.roger]\ncommand = \"/r\"\n[mcp_servers.\"crystalline\"]\ncommand = '/c'\n"
        #expect(HarnessRegistration.tomlCommand(text) == .command("/r"))
        #expect(HarnessRegistration.tomlCommand(text, server: "crystalline") == .command("/c"))
        #expect(HarnessRegistration.tomlCommand(text, server: "other") == .absent)
    }

    @Test func jsonServerNames() {
        let data = Data(#"{"mcpServers":{"roger":{"command":"/r"},"remote":{"url":"https://example.invalid"}}}"#.utf8)
        #expect(HarnessRegistration.jsonServers(data)?.sorted { $0.name < $1.name } == [
            ConfiguredServer(name: "remote", command: nil),
            ConfiguredServer(name: "roger", command: "/r"),
        ])
        #expect(HarnessRegistration.jsonServers(Data("{}".utf8)) == [])
        #expect(HarnessRegistration.jsonServers(Data("nope".utf8)) == nil)
    }

    @Test func tomlServerNames() {
        let text = """
        model = "x"
        [mcp_servers.roger] # Roger
        command = "/r"
        [mcp_servers.roger.tools.search]
        approval_mode = "approve"
        [mcp_servers.'Crystalline']
        url = "https://example.invalid"
        [profiles.fast]
        command = "/not-a-server"
        """
        #expect(HarnessRegistration.tomlServers(text) == [
            ConfiguredServer(name: "roger", command: "/r"),
            ConfiguredServer(name: "Crystalline", command: nil),
        ])
    }
}
