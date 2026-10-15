import Foundation

/// How a command runs.
enum CommandMode: String, Codable, CaseIterable, Identifiable {
    /// In the background, with a timeout. Nobody can answer questions.
    case headless
    /// In a new terminal window, so the user can answer.
    case interactive

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .headless: return "In the background"
        case .interactive: return "In a terminal window"
        }
    }
}

/// The terminal an interactive command opens in.
enum TerminalApp: String, Codable, CaseIterable, Identifiable {
    case terminal, iterm2, ghostty, warp

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        }
    }
    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        }
    }
}

/// A shell command the user configured in Settings > Commands. Log presets,
/// meetings and file transcripts can run one after Roger saved the item.
struct AgentCommand: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// Shell line; `{prompt}` and the item placeholders are shell-quoted.
    var commandLine: String
    /// Text with item placeholders, handed to `{prompt}`.
    var prompt: String
    /// "~" allowed. Expanded at run time.
    var workingDirectory: String
    var mode: CommandMode
    var terminal: TerminalApp
    /// Headless only.
    var timeoutMinutes: Int

    static let defaultTimeoutMinutes = 10
    static let headlessExampleLine = "claude -p {prompt}"
    static let interactiveExampleLine = "claude {prompt}"
    static let headlessExamplePrompt = "Use /ingest-roger to read what is new in Roger. Fold it into Crystalline with the ingestion method of crystalline-capture. Choose the domains by their routing. Keep tasks as [task] observations in the engrams they belong to. At the end, list the tasks you found."
    static let interactiveExamplePrompt = "Use /ingest-roger to read what is new in Roger. Fold it into Crystalline with the ingestion method of crystalline-capture. Choose the domains by their routing. Keep tasks as [task] observations in the engrams they belong to. At the end, list the tasks you found and ask me which ones to work on."

    init(
        id: UUID = UUID(),
        name: String,
        commandLine: String,
        prompt: String,
        workingDirectory: String,
        mode: CommandMode = .headless,
        terminal: TerminalApp = .terminal,
        timeoutMinutes: Int = AgentCommand.defaultTimeoutMinutes
    ) {
        self.id = id
        self.name = name
        self.commandLine = commandLine
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.mode = mode
        self.terminal = terminal
        self.timeoutMinutes = timeoutMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        commandLine = try c.decode(String.self, forKey: .commandLine)
        prompt = try c.decode(String.self, forKey: .prompt)
        workingDirectory = try c.decode(String.self, forKey: .workingDirectory)
        mode = try c.decodeIfPresent(CommandMode.self, forKey: .mode) ?? .headless
        terminal = try c.decodeIfPresent(TerminalApp.self, forKey: .terminal) ?? .terminal
        timeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .timeoutMinutes) ?? Self.defaultTimeoutMinutes
    }

    static func newClaudeExample() -> AgentCommand {
        AgentCommand(name: "Ingest into Crystalline", commandLine: headlessExampleLine,
                     prompt: headlessExamplePrompt, workingDirectory: "~")
    }

    mutating func setMode(_ newMode: CommandMode) {
        let untouched = (commandLine == Self.headlessExampleLine && prompt == Self.headlessExamplePrompt)
            || (commandLine == Self.interactiveExampleLine && prompt == Self.interactiveExamplePrompt)
        mode = newMode
        guard untouched else { return }
        switch newMode {
        case .headless:
            commandLine = Self.headlessExampleLine
            prompt = Self.headlessExamplePrompt
        case .interactive:
            commandLine = Self.interactiveExampleLine
            prompt = Self.interactiveExamplePrompt
        }
    }

    func expandedWorkingDirectory(home: URL) -> URL {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" || trimmed.isEmpty { return home }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))) }
        return URL(fileURLWithPath: trimmed)
    }
}
