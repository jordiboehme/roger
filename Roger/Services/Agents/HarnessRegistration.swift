import Foundation

struct RegistrationCommand: Equatable, Sendable {
    let cli: String
    let arguments: [String]

    /// The command as a user would type it.
    var display: String {
        ([cli] + arguments).map(McpCommandFormatter.shellQuoted).joined(separator: " ")
    }
}

/// One MCP server entry in a harness config.
struct ConfiguredServer: Equatable, Sendable {
    let name: String
    /// The executable (or, from `claude mcp list`, the URL or command line).
    var command: String?
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
            let lookup = spec.id == .codex ? tomlCommand(TextFile.decode(data)) : jsonCommand(data)
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

    /// `mcpServers.<server>.command` at the top level (user scope).
    static func jsonCommand(_ data: Data, server: String = "roger") -> ConfigLookup {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        guard let servers = object["mcpServers"] as? [String: Any],
              let entry = servers[server] as? [String: Any],
              let command = entry["command"] as? String
        else { return .absent }
        return .command(command)
    }

    /// Every server under the top-level `mcpServers`. Nil when the file is
    /// not a JSON object.
    static func jsonServers(_ data: Data) -> [ConfiguredServer]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().map { name in
            ConfiguredServer(name: name, command: (servers[name] as? [String: Any])?["command"] as? String)
        }
    }

    /// `command = "..."` inside `[mcp_servers.roger]`. Accepts what Codex
    /// and people write: spaces, a `# comment` after the header or the
    /// value, and the header as `[mcp_servers."roger"]` or
    /// `[mcp_servers.'roger']`. Also the inline form
    /// `roger = { command = "..." }` inside `[mcp_servers]`. The text comes
    /// from `TextFile` (LF).
    static func tomlCommand(_ text: String, server: String = "roger") -> ConfigLookup {
        var inSection = false
        var inServersTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = tomlTableName(line)
                inSection = name == ["mcp_servers", server]
                inServersTable = name == ["mcp_servers"]
                continue
            }
            guard inSection || inServersTable, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if inServersTable {
                if unquotedTOMLKey(parts[0]) == server { return tomlInlineCommand(parts[1]) }
                continue
            }
            guard unquotedTOMLKey(parts[0]) == "command" else { continue }
            guard let (value, rest) = tomlString(parts[1]) else { return .unreadable }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { return .unreadable }
            return .command(value)
        }
        return .absent
    }

    /// Every `[mcp_servers.<name>]` table and every inline
    /// `<name> = { ... }` inside `[mcp_servers]`, in file order, with its
    /// `command` when it has a readable one. Sub-tables such as `.tools.x`
    /// are skipped.
    static func tomlServers(_ text: String) -> [ConfiguredServer] {
        var servers: [ConfiguredServer] = []
        var current: Int?
        var inServersTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                let name = tomlTableName(line)
                inServersTable = name == ["mcp_servers"]
                if let parts = name, parts.count == 2, parts[0] == "mcp_servers" {
                    if let index = servers.firstIndex(where: { $0.name == parts[1] }) {
                        current = index
                    } else {
                        servers.append(ConfiguredServer(name: parts[1], command: nil))
                        current = servers.count - 1
                    }
                }
                continue
            }
            guard !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if inServersTable, parts[1].hasPrefix("{") {
                let name = unquotedTOMLKey(parts[0])
                guard !name.isEmpty, !servers.contains(where: { $0.name == name }) else { continue }
                var command: String?
                if case .command(let value) = tomlInlineCommand(parts[1]) { command = value }
                servers.append(ConfiguredServer(name: name, command: command))
                continue
            }
            guard let index = current, unquotedTOMLKey(parts[0]) == "command", let (value, _) = tomlString(parts[1]) else { continue }
            servers[index].command = value
        }
        return servers
    }

    /// The `command` of an inline table such as
    /// `{ command = "/x/roger-mcp", args = ["a, b"] }`. `.absent` when the
    /// table has none, `.unreadable` when it is not a one-line inline table.
    static func tomlInlineCommand(_ text: String) -> ConfigLookup {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        var rest = Substring(text).drop(while: isBlank)
        guard rest.first == "{" else { return .unreadable }
        rest = rest.dropFirst()
        while true {
            rest = rest.drop(while: isBlank)
            guard let first = rest.first else { return .unreadable }
            if first == "}" { return .absent }
            let key: String
            if first == "\"" || first == "'" {
                guard let (quoted, after) = tomlString(String(rest)) else { return .unreadable }
                key = quoted
                rest = rest.suffix(after.count)
            } else {
                let bare = rest.prefix { !isBlank($0) && $0 != "=" && $0 != "," && $0 != "}" }
                key = String(bare)
                rest = rest.dropFirst(bare.count)
            }
            rest = rest.drop(while: isBlank)
            guard !key.isEmpty, rest.first == "=" else { return .unreadable }
            rest = rest.dropFirst().drop(while: isBlank)
            if key == "command" {
                guard let (value, _) = tomlString(String(rest)) else { return .unreadable }
                return .command(value)
            }
            guard let after = skipTOMLValue(rest) else { return .unreadable }
            rest = after.drop(while: isBlank)
            if rest.first == "," {
                rest = rest.dropFirst()
            } else if rest.first == "}" {
                return .absent
            } else {
                return .unreadable
            }
        }
    }

    /// What follows the value at the start of `text`: a string, an array or
    /// an inline table (also nested), or a bare value up to `,` or `}`.
    private static func skipTOMLValue(_ text: Substring) -> Substring? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\"" || ch == "'" {
                guard let (_, after) = tomlString(String(text[index...])) else { return nil }
                index = text.index(text.endIndex, offsetBy: -after.count)
                if depth == 0 { return text[index...] }
                continue
            }
            if ch == "[" || ch == "{" {
                depth += 1
            } else if ch == "]" || ch == "}" {
                // A closing brace at depth 0 ends the enclosing table.
                if depth == 0 { return text[index...] }
                depth -= 1
                if depth == 0 { return text[text.index(after: index)...] }
            } else if ch == ",", depth == 0 {
                return text[index...]
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The dotted parts of `[a."b"]`, unquoted. Nil for `[[array]]` or a
    /// broken line. Spaces and a `# comment` may follow the `]`.
    static func tomlTableName(_ line: String) -> [String]? {
        guard line.hasPrefix("["), !line.hasPrefix("[[") else { return nil }
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var rest: Substring?
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let ch = line[index]
            index = line.index(after: index)
            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if ch == "]" {
                rest = line[index...]
                break
            } else {
                current.append(ch)
            }
        }
        guard let rest, quote == nil else { return nil }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        return parts + [current.trimmingCharacters(in: .whitespaces)]
    }

    private static func unquotedTOMLKey(_ key: String) -> String {
        guard key.count >= 2, let first = key.first, first == "\"" || first == "'", key.last == first else { return key }
        return String(key.dropFirst().dropLast())
    }

    /// A basic (`"..."`, with `\\` and `\"` escapes) or literal (`'...'`)
    /// string at the start of `text`, and what follows it.
    static func tomlString(_ text: String) -> (String, Substring)? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let ch = text[index]
            if ch == quote {
                return (value, text[text.index(after: index)...])
            }
            if quote == "\"", ch == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                switch text[next] {
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "t": value.append("\t")
                default: value.append("\\"); value.append(text[next])
                }
                index = text.index(after: next)
                continue
            }
            value.append(ch)
            index = text.index(after: index)
        }
        return nil
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
        case .stopped:
            return "\(cli) was stopped. Run this in Terminal:"
        case .exited(let code):
            let detail = result.stderr.split(separator: "\n").first.map { ": " + $0 } ?? ""
            return "\(cli) failed with exit code \(code)\(detail). Run this in Terminal:"
        }
    }
}
