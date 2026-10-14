import Foundation

struct RegistrationCommand: Equatable, Sendable {
    let cli: String
    let arguments: [String]

    /// The command as a user would type it.
    var display: String {
        ([cli] + arguments).map(McpCommandFormatter.shellQuoted).joined(separator: " ")
    }
}

enum ConfigLookup: Equatable, Sendable {
    case command(String)
    case absent
    case unreadable
}

enum ServerConnection: Equatable, Sendable {
    case connected
    /// Registered, but with another `roger-mcp` path (Roger moved, old copy).
    case otherCommand(String)
    case notConnected
    /// A config file exists but could not be read.
    case unknown
}

/// The CLI commands per harness (checked 2026-10-14, see Verified facts)
/// and the read-only config lookups for the "server connected" state.
enum HarnessRegistration {
    static func add(_ id: HarnessID, executable: String) -> RegistrationCommand? {
        switch id {
        case .claudeCode: return RegistrationCommand(cli: "claude", arguments: ["mcp", "add", "--scope", "user", "roger", "--", executable])
        case .codex: return RegistrationCommand(cli: "codex", arguments: ["mcp", "add", "roger", "--", executable])
        case .gemini: return RegistrationCommand(cli: "gemini", arguments: ["mcp", "add", "--scope", "user", "roger", executable])
        case .copilot: return RegistrationCommand(cli: "copilot", arguments: ["mcp", "add", "roger", "--", executable])
        case .kiro:
            // --command is one string to Kiro; a space would split it.
            guard !executable.contains(" ") else { return nil }
            return RegistrationCommand(cli: "kiro-cli", arguments: ["mcp", "add", "--name", "roger", "--command", executable, "--scope", "global"])
        case .cursor: return nil
        }
    }

    static func remove(_ id: HarnessID) -> RegistrationCommand? {
        switch id {
        case .claudeCode: return RegistrationCommand(cli: "claude", arguments: ["mcp", "remove", "--scope", "user", "roger"])
        case .codex: return RegistrationCommand(cli: "codex", arguments: ["mcp", "remove", "roger"])
        case .gemini: return RegistrationCommand(cli: "gemini", arguments: ["mcp", "remove", "--scope", "user", "roger"])
        case .copilot: return RegistrationCommand(cli: "copilot", arguments: ["mcp", "remove", "roger"])
        case .kiro: return RegistrationCommand(cli: "kiro-cli", arguments: ["mcp", "remove", "--name", "roger", "--scope", "global"])
        case .cursor: return nil
        }
    }

    /// What to paste into the harness's config file by hand.
    static func snippet(_ spec: HarnessSpec, executable: String) -> String {
        if spec.id == .codex {
            return "[mcp_servers.roger]\ncommand = \"\(executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\n"
        }
        return McpCommandFormatter.jsonSnippet(executable: executable)
    }

    /// Reads (never writes) the harness's config files in order. Without an
    /// executable to compare (Roger runs from a temporary place), any roger
    /// entry is `.otherCommand`.
    static func connection(_ spec: HarnessSpec, home: URL, executable: String?) -> ServerConnection {
        var sawUnreadable = false
        for file in spec.configFiles {
            guard let data = try? Data(contentsOf: home.appendingPathComponent(file)) else { continue }
            let lookup = spec.id == .codex ? tomlCommand(String(decoding: data, as: UTF8.self)) : jsonCommand(data)
            switch lookup {
            case .command(let command):
                guard let executable else { return .otherCommand(command) }
                return sameExecutable(command, executable) ? .connected : .otherCommand(command)
            case .absent:
                continue
            case .unreadable:
                sawUnreadable = true
            }
        }
        return sawUnreadable ? .unknown : .notConnected
    }

    /// `mcpServers.roger.command` at the top level (user scope).
    static func jsonCommand(_ data: Data) -> ConfigLookup {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard let servers = object["mcpServers"] as? [String: Any],
              let roger = servers["roger"] as? [String: Any],
              let command = roger["command"] as? String
        else { return .absent }
        return .command(command)
    }

    /// `command = "..."` inside `[mcp_servers.roger]`.
    static func tomlCommand(_ text: String) -> ConfigLookup {
        var inSection = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line == "[mcp_servers.roger]"
                continue
            }
            guard inSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "command" else { continue }
            let value = parts[1]
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return .unreadable }
            let inner = String(value.dropFirst().dropLast())
            return .command(quote == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\") : inner)
        }
        return .absent
    }

    private static func sameExecutable(_ a: String, _ b: String) -> Bool {
        a == b || URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }
}

struct RegistrationOutcome: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case registered
        case alreadyRegistered
        case removed
        /// The user has to do it: `message` says why, `command` is what to copy.
        case manual
    }

    let kind: Kind
    let message: String?
    let command: String?
}

/// Registers and removes the server through the harness CLI. Never edits a
/// config file. Every failure ends in `.manual` with the command to copy.
struct HarnessRegistrar: Sendable {
    let home: URL
    let runner: any CommandRunner
    let searchPath: [String]
    let timeout: Duration

    init(home: URL, runner: any CommandRunner, searchPath: [String], timeout: Duration = .seconds(20)) {
        self.home = home
        self.runner = runner
        self.searchPath = searchPath
        self.timeout = timeout
    }

    func register(_ spec: HarnessSpec, executable: String) async -> RegistrationOutcome {
        let current = HarnessRegistration.connection(spec, home: home, executable: executable)
        if current == .connected {
            return RegistrationOutcome(kind: .alreadyRegistered, message: nil, command: nil)
        }
        guard let add = HarnessRegistration.add(spec.id, executable: executable) else {
            let file = "~/" + (spec.configFiles.first ?? "")
            return RegistrationOutcome(kind: .manual, message: "Add Roger to \(file) yourself:", command: HarnessRegistration.snippet(spec, executable: executable))
        }
        guard let cli = CLILocator.find(add.cli, in: searchPath) else {
            return RegistrationOutcome(kind: .manual, message: "\(add.cli) was not found. Run this in Terminal:", command: add.display)
        }
        if case .otherCommand = current, let remove = HarnessRegistration.remove(spec.id) {
            let removed = await run(cli, remove)
            guard removed.succeeded else {
                return RegistrationOutcome(kind: .manual, message: reason(removed, cli: add.cli), command: remove.display + " && " + add.display)
            }
        }
        let added = await run(cli, add)
        guard added.succeeded else {
            return RegistrationOutcome(kind: .manual, message: reason(added, cli: add.cli), command: add.display)
        }
        return RegistrationOutcome(kind: .registered, message: nil, command: nil)
    }

    func unregister(_ spec: HarnessSpec, executable: String) async -> RegistrationOutcome {
        if HarnessRegistration.connection(spec, home: home, executable: executable) == .notConnected {
            return RegistrationOutcome(kind: .removed, message: nil, command: nil)
        }
        guard let remove = HarnessRegistration.remove(spec.id) else {
            let file = "~/" + (spec.configFiles.first ?? "")
            return RegistrationOutcome(kind: .manual, message: "Remove the roger entry from \(file) yourself.", command: nil)
        }
        guard let cli = CLILocator.find(remove.cli, in: searchPath) else {
            return RegistrationOutcome(kind: .manual, message: "\(remove.cli) was not found. Run this in Terminal:", command: remove.display)
        }
        let removed = await run(cli, remove)
        guard removed.succeeded else {
            return RegistrationOutcome(kind: .manual, message: reason(removed, cli: remove.cli), command: remove.display)
        }
        return RegistrationOutcome(kind: .removed, message: nil, command: nil)
    }

    private func run(_ cli: URL, _ command: RegistrationCommand) async -> CommandResult {
        await runner.run(
            cli,
            command.arguments,
            environment: ["PATH": searchPath.joined(separator: ":"), "HOME": home.path, "USER": NSUserName()],
            currentDirectory: home,
            timeout: timeout
        )
    }

    private func reason(_ result: CommandResult, cli: String) -> String {
        switch result.status {
        case .timedOut:
            return "\(cli) did not answer within \(Int(timeout.components.seconds)) seconds. It may wait for a login or a question. Run this in Terminal:"
        case .failedToStart(let message):
            return "\(cli) could not start (\(message)). Run this in Terminal:"
        case .exited(let code):
            let detail = result.stderr.split(separator: "\n").first.map { ": " + $0 } ?? ""
            return "\(cli) failed with exit code \(code)\(detail). Run this in Terminal:"
        }
    }
}
