import Foundation
import Testing
@testable import Roger

/// Records calls and answers with canned results (the last one repeats).
final class FakeRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var results: [CommandResult]

    init(_ results: [CommandResult]) { self.results = results }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult {
        lock.withLock {
            recorded.append([executable.lastPathComponent] + arguments)
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

/// Holds every call of one CLI until `open()`; other calls succeed at once.
final class GateRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let gated: String
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var recorded: [String] = []

    init(gating cli: String) { gated = cli }

    var calls: [String] { lock.withLock { recorded } }

    func open() {
        let resumes = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumes.forEach { $0.resume() }
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult {
        let name = executable.lastPathComponent
        lock.withLock { recorded.append(name) }
        if name == gated {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return CommandResult(status: .exited(0), stdout: "", stderr: "")
    }
}

struct HarnessRegistrationTests {
    private let exe = "/Applications/Roger.app/Contents/MacOS/roger-mcp"
    private let ok = CommandResult(status: .exited(0), stdout: "", stderr: "")

    private func home(with clis: [String]) throws -> (home: URL, bin: URL) {
        let home = try TempFolder.make()
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for cli in clis {
            let url = bin.appendingPathComponent(cli)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return (home, bin)
    }

    @Test func addAndRemoveArguments() {
        #expect(HarnessRegistration.add(.claudeCode, executable: exe) == RegistrationCommand(cli: "claude", arguments: ["mcp", "add", "--scope", "user", "roger", "--", exe]))
        #expect(HarnessRegistration.add(.codex, executable: exe) == RegistrationCommand(cli: "codex", arguments: ["mcp", "add", "roger", "--", exe]))
        #expect(HarnessRegistration.add(.gemini, executable: exe) == RegistrationCommand(cli: "gemini", arguments: ["mcp", "add", "--scope", "user", "roger", exe]))
        #expect(HarnessRegistration.add(.copilot, executable: exe) == RegistrationCommand(cli: "copilot", arguments: ["mcp", "add", "roger", "--", exe]))
        #expect(HarnessRegistration.add(.kiro, executable: exe) == RegistrationCommand(cli: "kiro-cli", arguments: ["mcp", "add", "--name", "roger", "--command", exe, "--scope", "global"]))
        #expect(HarnessRegistration.add(.cursor, executable: exe) == nil)
        #expect(HarnessRegistration.remove(.claudeCode) == RegistrationCommand(cli: "claude", arguments: ["mcp", "remove", "--scope", "user", "roger"]))
        #expect(HarnessRegistration.remove(.gemini) == RegistrationCommand(cli: "gemini", arguments: ["mcp", "remove", "--scope", "user", "roger"]))
        #expect(HarnessRegistration.remove(.kiro) == RegistrationCommand(cli: "kiro-cli", arguments: ["mcp", "remove", "--name", "roger", "--scope", "global"]))
        #expect(HarnessRegistration.add(.claudeCode, executable: "/My Apps/roger-mcp")?.display == "claude mcp add --scope user roger -- '/My Apps/roger-mcp'")
    }

    @Test func kiroPathWithASpaceGetsTheSnippet() {
        #expect(HarnessRegistration.add(.kiro, executable: "/Users/x/My Apps/Roger.app/Contents/MacOS/roger-mcp") == nil)
    }

    @Test func readsJSONConfigs() {
        #expect(HarnessRegistration.jsonCommand(Data(#"{"mcpServers":{"roger":{"command":"/a/roger-mcp","args":[]}}}"#.utf8)) == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.jsonCommand(Data(#"{"mcpServers":{"other":{"command":"x"}}}"#.utf8)) == .absent)
        #expect(HarnessRegistration.jsonCommand(Data(#"{"projects":{}}"#.utf8)) == .absent)
        #expect(HarnessRegistration.jsonCommand(Data("{ nope".utf8)) == .unreadable)
    }

    @Test func readsCodexTOML() {
        let toml = """
        model = "gpt-5"

        [mcp_servers.other]
        command = "x"

        [mcp_servers.roger]
        command = "/a/roger-mcp"
        args = []
        """
        #expect(HarnessRegistration.tomlCommand(toml) == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.other]\ncommand = \"x\"\n") == .absent)
    }

    @Test func codexConfigComesFromCodexHomeWhenSet() throws {
        let (home, _) = try home(with: [])
        defer { TempFolder.remove(home) }
        let spec = HarnessCatalog.spec(.codex)
        let custom = home.appendingPathComponent("work-codex/config.toml")
        try FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[mcp_servers.roger]\ncommand = \"\(exe)\"\n".utf8).write(to: custom)
        // Without CODEX_HOME, ~/.codex is read and has nothing.
        #expect(HarnessRegistration.connection(spec, home: home, executable: exe) == .notConnected)
        #expect(HarnessRegistration.connection(spec, home: home, executable: exe, codexHome: custom.deletingLastPathComponent().path) == .connected)
        #expect(HarnessRegistration.connection(spec, home: home, executable: exe, codexHome: "~/work-codex") == .connected)

        #expect(spec.configURLs(home: home, codexHome: nil) == [home.appendingPathComponent(".codex/config.toml")])
        #expect(spec.configURLs(home: home, codexHome: "relative/dir") == [home.appendingPathComponent(".codex/config.toml")])
        #expect(spec.configURLs(home: home, codexHome: "/opt/codex").map(\.path) == ["/opt/codex/config.toml"])
        // Other harnesses ignore it.
        let claude = HarnessCatalog.spec(.claudeCode)
        #expect(claude.configURLs(home: home, codexHome: "/opt/codex") == [home.appendingPathComponent(".claude.json")])
    }

    @Test func readsACRLFCodexConfig() throws {
        let (home, _) = try home(with: [])
        defer { TempFolder.remove(home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt-5\"\r\n\r\n[mcp_servers.roger]\r\ncommand = \"\(exe)\"\r\n".utf8).write(to: config)
        #expect(HarnessRegistration.connection(HarnessCatalog.spec(.codex), home: home, executable: exe) == .connected)
    }

    @Test func connectionComparesTheCommand() throws {
        let (home, _) = try home(with: [])
        defer { TempFolder.remove(home) }
        let spec = HarnessCatalog.spec(.kiro)
        #expect(HarnessRegistration.connection(spec, home: home, executable: exe) == .notConnected)
        let config = home.appendingPathComponent(".kiro/settings/mcp.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"roger":{"command":"/old/roger-mcp"}}}"#.utf8).write(to: config)
        #expect(HarnessRegistration.connection(spec, home: home, executable: exe) == .otherCommand("/old/roger-mcp"))
        try Data(#"{"mcpServers":{"roger":{"command":"\#(exe)"}}}"#.utf8).write(to: config)
        #expect(HarnessRegistration.connection(spec, home: home, executable: exe) == .connected)
    }

    /// kiro-cli 2.31.1 never reads `~/.kiro/mcp.json` (`kiro-cli mcp list`
    /// does not show a server there), so Roger does not either.
    @Test func kiroIgnoresTheTopLevelMcpFile() throws {
        let (home, _) = try home(with: [])
        defer { TempFolder.remove(home) }
        let file = home.appendingPathComponent(".kiro/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"roger":{"command":"\#(exe)"}}}"#.utf8).write(to: file)
        #expect(HarnessRegistration.connection(HarnessCatalog.spec(.kiro), home: home, executable: exe) == .notConnected)
    }

    @Test func registersThroughTheCLI() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        let runner = FakeRunner([ok])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).register(HarnessCatalog.spec(.claudeCode), executable: exe)
        #expect(outcome.kind == .registered)
        #expect(runner.calls == [["claude", "mcp", "add", "--scope", "user", "roger", "--", exe]])
    }

    @Test func missingCLIShowsTheCommand() async throws {
        let (home, bin) = try home(with: [])
        defer { TempFolder.remove(home) }
        let runner = FakeRunner([ok])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).register(HarnessCatalog.spec(.codex), executable: exe)
        #expect(outcome.kind == .manual)
        #expect(outcome.command == "codex mcp add roger -- \(exe)")
        #expect(outcome.message?.contains("codex was not found") == true)
        #expect(runner.calls.isEmpty)
    }

    @Test func failingCLIShowsTheCommandAndTheReason() async throws {
        let (home, bin) = try home(with: ["gemini"])
        defer { TempFolder.remove(home) }
        let runner = FakeRunner([CommandResult(status: .exited(1), stdout: "", stderr: "Error: not logged in\nmore")])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).register(HarnessCatalog.spec(.gemini), executable: exe)
        #expect(outcome.kind == .manual)
        #expect(outcome.message?.contains("Error: not logged in") == true)
        #expect(outcome.command == "gemini mcp add --scope user roger \(exe)")
    }

    @Test func timedOutRegistrationShowsTheCommand() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        let runner = FakeRunner([CommandResult(status: .timedOut, stdout: "", stderr: "")])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).register(HarnessCatalog.spec(.claudeCode), executable: exe)
        #expect(outcome.kind == .manual)
        #expect(outcome.message?.contains("did not answer within 20 seconds") == true)
        #expect(outcome.command == "claude mcp add --scope user roger -- \(exe)")
    }

    @Test func otherPathMeansReRegister() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        try Data(#"{"mcpServers":{"roger":{"command":"/Volumes/Roger/Roger.app/Contents/MacOS/roger-mcp"}}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        let runner = FakeRunner([ok])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).register(HarnessCatalog.spec(.claudeCode), executable: exe)
        #expect(outcome.kind == .registered)
        #expect(runner.calls == [
            ["claude", "mcp", "remove", "--scope", "user", "roger"],
            ["claude", "mcp", "add", "--scope", "user", "roger", "--", exe],
        ])
    }

    @Test func alreadyRegisteredRunsNothing() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        try Data(#"{"mcpServers":{"roger":{"command":"\#(exe)"}}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        let runner = FakeRunner([ok])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).register(HarnessCatalog.spec(.claudeCode), executable: exe)
        #expect(outcome.kind == .alreadyRegistered)
        #expect(runner.calls.isEmpty)
    }

    @Test func cursorGetsASnippetAndNoConfigWrite() async throws {
        let (home, bin) = try home(with: [])
        defer { TempFolder.remove(home) }
        let outcome = await HarnessRegistrar(home: home, runner: FakeRunner([ok]), searchPath: [bin.path]).register(HarnessCatalog.spec(.cursor), executable: exe)
        #expect(outcome.kind == .manual)
        #expect(outcome.message?.contains("~/.cursor/mcp.json") == true)
        #expect(outcome.command == McpCommandFormatter.jsonSnippet(executable: exe))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/mcp.json").path))
    }

    @Test func unregisterRemovesThroughTheCLI() async throws {
        let (home, bin) = try home(with: ["codex"])
        defer { TempFolder.remove(home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("[mcp_servers.roger]\ncommand = \"\(exe)\"\n".utf8).write(to: home.appendingPathComponent(".codex/config.toml"))
        let runner = FakeRunner([ok])
        let outcome = await HarnessRegistrar(home: home, runner: runner, searchPath: [bin.path]).unregister(HarnessCatalog.spec(.codex), executable: exe)
        #expect(outcome.kind == .removed)
        #expect(runner.calls == [["codex", "mcp", "remove", "roger"]])
    }

    @Test(arguments: [
        (true, nil as String?, "0.25.0", true),
        (true, "0.25.0", "0.25.0", false),
        (true, "0.24.0", "0.25.0", true),
        (false, nil as String?, "0.25.0", false),
    ])
    func hintShowsWhileOutdatedAndNotDismissed(outdated: Bool, dismissed: String?, version: String, expected: Bool) {
        #expect(AgentsHint.shouldShow(outdated: outdated, dismissedVersion: dismissed, appVersion: version) == expected)
    }

    @MainActor
    @Test func installWritesTheSkillAndRegisters() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let app = home.appendingPathComponent("Applications/Roger.app", isDirectory: true)
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let runner = FakeRunner([ok])
        let controller = AgentsController(home: home, installer: installer, runner: runner, appBundle: app, searchPath: [bin.path], links: [])
        await controller.refresh()
        #expect(controller.rows.map(\.id) == [.claudeCode])
        await controller.install(.claudeCode)
        #expect(installer.state(of: home.appendingPathComponent(".claude/skills")) == .upToDate)
        #expect(runner.calls.first?.prefix(3) == ["claude", "mcp", "add"])
        #expect(controller.rows.first?.manualCommand == nil)
    }

    @MainActor
    private func installedRow(_ id: HarnessID, folder: String, clis: [String], result: CommandResult) async throws -> (home: URL, row: AgentsController.Row) {
        let (home, bin) = try home(with: clis)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let app = home.appendingPathComponent("Applications/Roger.app", isDirectory: true)
        let controller = AgentsController(home: home, installer: installer, runner: FakeRunner([result]), appBundle: app, searchPath: [bin.path], links: [])
        await controller.refresh()
        await controller.install(id)
        let row = try #require(controller.rows.first { $0.id == id })
        #expect(row.skillState == .upToDate)
        #expect(row.connection == .notConnected)
        return (home, row)
    }

    /// Without a CLI Roger cannot add the server, so the button only shows
    /// what to do by hand.
    @MainActor
    @Test func harnessWithoutACLIShowsSetup() async throws {
        let (home, row) = try await installedRow(.cursor, folder: ".cursor", clis: [], result: ok)
        defer { TempFolder.remove(home) }
        #expect(row.hasCLI == false)
        #expect(row.primaryAction == "Show setup")
    }

    @MainActor
    @Test func missingCLIShowsSetup() async throws {
        let (home, row) = try await installedRow(.claudeCode, folder: ".claude", clis: [], result: ok)
        defer { TempFolder.remove(home) }
        #expect(row.hasCLI == false)
        #expect(row.manualCommand?.hasPrefix("claude mcp add") == true)
        #expect(row.primaryAction == "Show setup")
    }

    /// Cursor reads the skill Claude Code installed; its row still only
    /// needs the server, which Roger cannot add.
    @MainActor
    @Test func coveredRowWithoutACLIShowsSetup() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        for folder in [".claude", ".cursor"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let app = home.appendingPathComponent("Applications/Roger.app", isDirectory: true)
        let controller = AgentsController(home: home, installer: installer, runner: FakeRunner([ok]), appBundle: app, searchPath: [bin.path], links: [])
        await controller.refresh()
        await controller.install(.claudeCode)
        let cursor = try #require(controller.rows.first { $0.id == .cursor })
        #expect(cursor.coveredBy == .claudeCode)
        #expect(cursor.connection == .notConnected)
        #expect(cursor.primaryAction == "Show setup")
    }

    /// The rows show before the login shell answered; the CLI check
    /// follows once it did.
    @MainActor
    @Test func cliIsCheckedAfterTheLoginShellAnswered() async throws {
        let (home, bin) = try home(with: [])
        defer { TempFolder.remove(home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let app = home.appendingPathComponent("Applications/Roger.app", isDirectory: true)
        let shell = CommandResult(status: .exited(0), stdout: "__ROGER_PATH__\(bin.path)__ROGER_PATH__", stderr: "")
        let runner = FakeRunner([shell])
        let controller = AgentsController(home: home, installer: installer, runner: runner, appBundle: app, links: [])
        await controller.refresh()
        // Homebrew's folders are always searched, so a real claude there counts.
        let expected = CLILocator.find("claude", in: CLILocator.searchPath(loginShellPATH: bin.path, home: home)) != nil
        #expect(runner.calls.count == 1)
        #expect(controller.rows.map(\.id) == [.claudeCode])
        #expect(controller.rows.first?.hasCLI == expected)
    }

    @MainActor
    @Test func failedRegistrationWithTheCLIOffersUpdate() async throws {
        let failed = CommandResult(status: .exited(1), stdout: "", stderr: "boom")
        let (home, row) = try await installedRow(.claudeCode, folder: ".claude", clis: ["claude"], result: failed)
        defer { TempFolder.remove(home) }
        #expect(row.hasCLI)
        #expect(row.primaryAction == "Update")
    }

    @MainActor
    @Test func unusableExecutableStillReadsTheConfig() async throws {
        let (home, bin) = try home(with: ["claude"])
        defer { TempFolder.remove(home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let dmg = URL(fileURLWithPath: "/Volumes/Roger/Roger.app", isDirectory: true)
        let controller = AgentsController(home: home, installer: installer, runner: FakeRunner([ok]), appBundle: dmg, searchPath: [bin.path], links: [])
        guard case .unusable = controller.executableChoice else {
            Issue.record("expected an unusable executable")
            return
        }
        await controller.refresh()
        var row = try #require(controller.rows.first)
        #expect(row.connection == .notConnected)
        #expect(row.primaryAction == "Install")
        #expect(row.canUninstall == false)

        let config = home.appendingPathComponent(".claude.json")
        try Data(#"{"mcpServers":{"roger":{"command":"/Applications/Roger.app/Contents/MacOS/roger-mcp"}}}"#.utf8).write(to: config)
        await controller.refresh()
        row = try #require(controller.rows.first)
        #expect(row.connection == .otherCommand("/Applications/Roger.app/Contents/MacOS/roger-mcp"))
        #expect(row.canUninstall)

        try Data("{ nope".utf8).write(to: config)
        await controller.refresh()
        row = try #require(controller.rows.first)
        #expect(row.connection == .unknown)
        #expect(row.primaryAction == "Install")
        #expect(row.canUninstall == false)
    }

    @MainActor
    @Test func anotherRowKeepsItsSpinner() async throws {
        let (home, bin) = try home(with: ["claude", "kiro-cli"])
        defer { TempFolder.remove(home) }
        for folder in [".claude", ".kiro"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let runner = GateRunner(gating: "claude")
        let app = home.appendingPathComponent("Applications/Roger.app", isDirectory: true)
        let controller = AgentsController(home: home, installer: installer, runner: runner, appBundle: app, searchPath: [bin.path], links: [])
        await controller.refresh()
        let claude = Task { await controller.install(.claudeCode) }
        while !runner.calls.contains("claude") { await Task.yield() }
        await controller.install(.kiro)
        #expect(controller.rows.first { $0.id == .claudeCode }?.isBusy == true)
        #expect(controller.rows.first { $0.id == .kiro }?.isBusy == false)
        runner.open()
        await claude.value
        #expect(controller.rows.first { $0.id == .claudeCode }?.isBusy == false)
    }

    @MainActor
    private func executable(_ controller: AgentsController) throws -> String {
        guard case .usable(let path) = controller.executableChoice else { throw CancellationError() }
        return path
    }

    @MainActor
    private func codexAndGemini() async throws -> (home: URL, controller: AgentsController, installer: SkillInstaller, runner: FakeRunner) {
        let (home, bin) = try home(with: ["codex", "gemini"])
        for folder in [".codex", ".gemini"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let skill = BundledSkill(content: Data("---\nname: ingest-roger\n---\n".utf8), version: "0.25.0")
        let installer = SkillInstaller(home: home, receiptURL: home.appendingPathComponent("receipt.json"), skill: skill, trash: { _ in })
        let runner = FakeRunner([ok])
        let app = home.appendingPathComponent("Applications/Roger.app", isDirectory: true)
        let controller = AgentsController(home: home, installer: installer, runner: runner, appBundle: app, searchPath: [bin.path], links: [])
        await controller.refresh()
        return (home, controller, installer, runner)
    }

    @MainActor
    @Test func coveredRowInstallsTheSkillWhileTheCoverHasNone() async throws {
        let (home, controller, installer, runner) = try await codexAndGemini()
        defer { TempFolder.remove(home) }
        let gemini = try #require(controller.rows.first { $0.id == .gemini })
        #expect(gemini.plan.coveredBy == .codex)
        #expect(gemini.coveredBy == nil)
        #expect(gemini.skillState == .notInstalled)
        #expect(gemini.primaryAction == "Install")
        await controller.install(.gemini)
        #expect(installer.state(of: home.appendingPathComponent(".agents/skills")) == .upToDate)
        #expect(runner.calls == [["gemini", "mcp", "add", "--scope", "user", "roger", try executable(controller)]])
    }

    @MainActor
    @Test func coveredRowShowsTheCoverOnceItsSkillIsThere() async throws {
        let (home, controller, _, runner) = try await codexAndGemini()
        defer { TempFolder.remove(home) }
        await controller.install(.codex)
        let gemini = try #require(controller.rows.first { $0.id == .gemini })
        #expect(gemini.coveredBy == .codex)
        #expect(gemini.primaryAction == "Install")
        #expect(gemini.canUninstall == false)
        await controller.install(.gemini)
        #expect(runner.calls.last == ["gemini", "mcp", "add", "--scope", "user", "roger", try executable(controller)])
    }

    @Test func codexTOMLWithCommentsAndQuotedHeaders() {
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = \"/a/roger-mcp\" # added by Roger\n") == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.\"roger\"]\ncommand = \"/a/roger-mcp\"\n") == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[ mcp_servers . 'roger' ] # Roger\ncommand='/a/roger-mcp'\n") == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\n# command = \"/old\"\ncommand = \"/a/#1/roger-mcp\"\n") == .command("/a/#1/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = \"/a/\\\"x\\\"/roger-mcp\"\n") == .command("/a/\"x\"/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.\"roger.other\"]\ncommand = \"x\"\n") == .absent)
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = \"/a/roger-mcp\" trailing\n") == .unreadable)
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = [\"/a/roger-mcp\"]\n") == .unreadable)
    }

    @Test func tomlTableNames() {
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.roger]") == ["mcp_servers", "roger"])
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.\"roger\"] # x") == ["mcp_servers", "roger"])
        #expect(HarnessRegistration.tomlTableName("[[mcp_servers]]") == nil)
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.roger] x") == nil)
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.\"roger]") == nil)
    }
}
