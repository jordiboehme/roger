import Foundation

/// One ready command for a coding agent found on this Mac.
struct CommandSuggestion: Identifiable, Equatable {
    let id: String                 // "<harness>-<mode>"
    let harness: HarnessID
    let mode: CommandMode
    let title: String              // "Claude Code, in the background"
    let disabledReason: String?    // "Roger not connected, see Agents" when roger is missing
    let command: AgentCommand      // ready to append (fresh UUID each build)
    /// The prompt folds the items into Crystalline (else a plain summary).
    let usesCrystalline: Bool
}

/// Builds the commands that "Suggest Commands" offers. Flags were checked on
/// 2026-10-15: Claude Code with its own `--help` and a test run, the others
/// (not installed here) against their docs. Gemini CLI and Kiro have no
/// documented way to allow only some MCP servers in a one-shot run, so they
/// are offered in a terminal window only.
enum CommandSuggestions {
    static let crystallineHeadlessPrompt = "Use the ingest-roger skill to read what is new in Roger. Fold it into Crystalline with the ingestion method of crystalline-capture. Choose the domains by their routing. Keep tasks as [task] observations in the engrams they belong to. At the end, list the tasks you found."
    static let crystallineInteractivePrompt = "Use the ingest-roger skill to read what is new in Roger. Fold it into Crystalline with the ingestion method of crystalline-capture. Choose the domains by their routing. Keep tasks as [task] observations in the engrams they belong to. At the end, list the tasks you found and ask me which ones to work on."
    static let plainHeadlessPrompt = "Use the ingest-roger skill to read what is new in Roger. Summarize it and list the tasks you found."
    static let plainInteractivePrompt = "Use the ingest-roger skill to read what is new in Roger. Summarize it, list the tasks you found and ask me which ones to work on."

    static let rogerMissing = "Roger not connected, see Agents"

    /// Modes this harness supports, with the command line for each (nil = not offered).
    static func commandLine(for harness: HarnessID, mode: CommandMode, servers: HarnessServers) -> String? {
        switch (harness, mode) {
        case (.claudeCode, .headless):
            // `--allowedTools` takes a list and would swallow the prompt
            // without the `--`.
            let tools = [servers.rogerToolPrefix, servers.crystallineToolPrefix].compactMap { $0 }
            guard !tools.isEmpty else { return "claude -p {prompt}" }
            return "claude -p --allowedTools \(quoted(tools.joined(separator: ","))) -- {prompt}"
        case (.claudeCode, .interactive):
            return "claude {prompt}"
        case (.codex, .headless):
            // `codex exec` never asks, so MCP tools that would ask are
            // refused unless their server approves them. It also refuses to
            // run outside a Git repository without the flag.
            let names = [HarnessServers.rogerServerName] + [codexCrystalline(servers)].compactMap { $0 }
            let overrides = names.map { "-c " + quoted("mcp_servers.\($0).default_tools_approval_mode=\"approve\"") }
            return (["codex exec --skip-git-repo-check"] + overrides + ["{prompt}"]).joined(separator: " ")
        case (.codex, .interactive):
            return "codex {prompt}"
        case (.gemini, .interactive):
            return "gemini -i {prompt}"
        case (.copilot, .headless):
            let names = [HarnessServers.rogerServerName] + [servers.crystallineServerName].compactMap { $0 }
            return (["copilot -p {prompt}"] + names.map { "--allow-tool=" + quoted($0) }).joined(separator: " ")
        case (.copilot, .interactive):
            return "copilot -i {prompt}"
        case (.kiro, .interactive):
            return "kiro-cli chat {prompt}"
        case (.gemini, .headless), (.kiro, .headless), (.cursor, _):
            return nil
        }
    }

    static func suggestions(for harnesses: [(HarnessID, HarnessServers)]) -> [CommandSuggestion] {
        HarnessCatalog.all.flatMap { spec -> [CommandSuggestion] in
            guard let servers = harnesses.first(where: { $0.0 == spec.id })?.1 else { return [] }
            return [CommandMode.headless, .interactive].compactMap { mode in
                guard let line = commandLine(for: spec.id, mode: mode, servers: servers) else { return nil }
                let crystalline = usesCrystalline(spec.id, servers)
                let prompt: String
                switch (mode, crystalline) {
                case (.headless, true): prompt = crystallineHeadlessPrompt
                case (.interactive, true): prompt = crystallineInteractivePrompt
                case (.headless, false): prompt = plainHeadlessPrompt
                case (.interactive, false): prompt = plainInteractivePrompt
                }
                let isHeadless = mode == .headless
                return CommandSuggestion(
                    id: "\(spec.id.rawValue)-\(mode.rawValue)",
                    harness: spec.id,
                    mode: mode,
                    title: "\(spec.name), \(isHeadless ? "in the background" : "in a terminal window")",
                    disabledReason: servers.rogerToolPrefix == nil ? rogerMissing : nil,
                    command: AgentCommand(
                        name: isHeadless ? "\(spec.name) ingest" : "\(spec.name) ingest (terminal)",
                        commandLine: line,
                        prompt: prompt,
                        workingDirectory: "~",
                        mode: mode
                    ),
                    usesCrystalline: crystalline
                )
            }
        }
    }

    /// Crystalline only when the command can allow its tools: Claude Code
    /// needs the prefix, Copilot the name, Codex a name that is a bare
    /// TOML key in `-c`.
    private static func usesCrystalline(_ harness: HarnessID, _ servers: HarnessServers) -> Bool {
        switch harness {
        case .codex: return codexCrystalline(servers) != nil
        case .copilot: return servers.crystallineServerName != nil
        default: return servers.crystallineToolPrefix != nil
        }
    }

    private static func codexCrystalline(_ servers: HarnessServers) -> String? {
        guard let name = servers.crystallineServerName,
              name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return name
    }

    /// Always single quotes, so the line reads the same for every value.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
