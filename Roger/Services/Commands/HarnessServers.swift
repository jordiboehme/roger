import Foundation
import os

/// The MCP servers of one harness that the suggested commands care about.
struct HarnessServers: Equatable, Sendable {
    /// Tool-name prefix of the Roger server (e.g. "mcp__roger"), nil when Roger is not registered.
    var rogerToolPrefix: String?
    /// Tool-name prefix of a Crystalline server (e.g. "mcp__crystalline" or "mcp__claude_ai_Crystalline"), nil when none.
    var crystallineToolPrefix: String?
    /// The Crystalline server's name in the harness config, for harnesses
    /// that allow tools by server name. Nil when there is none.
    var crystallineServerName: String? = nil

    static let rogerServerName = "roger"
}

extension HarnessServers {
    /// Roger is the server named `roger`. Crystalline is the first server
    /// named `crystalline` (any case, also as a claude.ai connector) or
    /// whose command is the `crystalline` binary.
    init(configured: [ConfiguredServer]) {
        self.init(rogerToolPrefix: nil, crystallineToolPrefix: nil)
        if configured.contains(where: { $0.name == Self.rogerServerName }) {
            rogerToolPrefix = Self.toolPrefix(serverName: Self.rogerServerName)
        }
        if let crystalline = configured.first(where: Self.isCrystalline) {
            crystallineToolPrefix = Self.toolPrefix(serverName: crystalline.name)
            crystallineServerName = crystalline.name
        }
    }

    static func isCrystalline(_ server: ConfiguredServer) -> Bool {
        var name = server.name
        if name.hasPrefix(Self.connectorPrefix) { name.removeFirst(Self.connectorPrefix.count) }
        if name.lowercased() == "crystalline" { return true }
        guard let command = server.command else { return false }
        // The executable may be followed by arguments; its path may hold spaces.
        return command.range(of: #"(^|/)crystalline( |$)"#, options: .regularExpression) != nil
    }

    /// Claude Code's tool names: `mcp__<server>__<tool>`, with every
    /// character outside letters, digits, `_` and `-` as `_`. A claude.ai
    /// connector "claude.ai Crystalline" becomes `mcp__claude_ai_Crystalline`.
    static func toolPrefix(serverName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let cleaned = String(String.UnicodeScalarView(serverName.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return "mcp__" + cleaned
    }

    static let connectorPrefix = "claude.ai "
}

/// Reads the output of `claude mcp list`. Lines look like
/// `name: <command or URL> [(HTTP)] - <status>`; other lines are skipped.
enum ClaudeMcpList {
    static func parse(_ output: String) -> [ConfiguredServer] {
        output.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.range(of: ": ") else { return nil }
            let name = String(line[..<colon.lowerBound])
            guard !name.isEmpty, !name.contains("`") else { return nil }
            var target = String(line[colon.upperBound...])
            if let status = target.range(of: " - ", options: .backwards) {
                target = String(target[..<status.lowerBound])
            }
            target = target.trimmingCharacters(in: .whitespaces)
            for transport in [" (HTTP)", " (SSE)", " (stdio)"] where target.hasSuffix(transport) {
                target.removeLast(transport.count)
            }
            return ConfiguredServer(name: name, command: target.isEmpty ? nil : target)
        }
    }
}

/// Finds the harnesses whose CLI is on the search path and their servers.
/// Reads config files (never writes them). For Claude Code it also asks
/// `claude mcp list`, which knows the claude.ai connectors.
struct HarnessServerDetector: Sendable {
    let home: URL
    let runner: any CommandRunner
    let searchPath: [String]
    /// `CODEX_HOME` from the login shell, nil when it is not set.
    var codexHome: String? = nil
    var timeout: Duration = .seconds(20)

    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "CommandSuggestions")

    func detect() async -> [(HarnessID, HarnessServers)] {
        var found: [(HarnessID, HarnessServers)] = []
        for (spec, executable) in findCLIs() {
            var servers = configuredServers(spec)
            if spec.id == .claudeCode, case .servers(let listed) = await claudeMcpList(executable) {
                servers += listed
            }
            found.append((spec.id, HarnessServers(configured: servers)))
        }
        return found
    }

    /// The harnesses whose CLI is on the search path, in catalog order, each
    /// with the CLI in the first folder that holds it. `checking` gets each
    /// folder before it is looked at (a privacy prompt or a dead network
    /// folder can block there). Blocks: call it off the main actor.
    func findCLIs(checking: (String) -> Void = { _ in }) -> [(HarnessSpec, URL)] {
        let specs = HarnessCatalog.all.filter { $0.cli != nil }
        var found: [HarnessID: URL] = [:]
        for directory in searchPath {
            guard found.count < specs.count else { break }
            checking(directory)
            for spec in specs where found[spec.id] == nil {
                guard let cli = spec.cli else { continue }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(cli)
                if FileManager.default.isExecutableFile(atPath: url.path) { found[spec.id] = url }
            }
        }
        return specs.compactMap { spec in found[spec.id].map { (spec, $0) } }
    }

    /// The servers in the harness's config files. Blocks: call it off the
    /// main actor.
    func configuredServers(_ spec: HarnessSpec) -> [ConfiguredServer] {
        spec.configURLs(home: home, codexHome: codexHome).flatMap { file -> [ConfiguredServer] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            if spec.id == .codex { return HarnessRegistration.tomlServers(TextFile.decode(data)) }
            return HarnessRegistration.jsonServers(data) ?? []
        }
    }

    enum ClaudeListOutcome: Equatable, Sendable {
        case servers([ConfiguredServer])
        /// The call failed or timed out: only the config counts.
        case failed(CommandResult.Status)
    }

    /// `claude mcp list`, which also knows the claude.ai connectors.
    func claudeMcpList(_ executable: URL) async -> ClaudeListOutcome {
        let result = await runner.run(
            executable,
            ["mcp", "list"],
            environment: ["PATH": searchPath.joined(separator: ":"), "HOME": home.path, "USER": NSUserName()],
            currentDirectory: home,
            timeout: timeout
        )
        guard result.succeeded else {
            Self.logger.info("claude mcp list did not work (\(String(describing: result.status), privacy: .public)), using the config only")
            return .failed(result.status)
        }
        return .servers(ClaudeMcpList.parse(result.stdout))
    }
}
