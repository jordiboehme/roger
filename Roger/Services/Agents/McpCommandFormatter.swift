import Foundation

/// Commands and config snippets the Agents tab offers to copy.
enum McpCommandFormatter {
    /// As is when it only has safe characters, else in single quotes.
    static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:@")
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func claudeAdd(executable: String) -> String {
        "claude mcp add --scope user roger -- " + shellQuoted(executable)
    }

    /// `{"mcpServers": {"roger": {"command": ..., "args": []}}}` for
    /// `.mcp.json`, Cursor, Copilot CLI, Kiro and other clients.
    static func jsonSnippet(executable: String) -> String {
        let object: [String: Any] = ["mcpServers": ["roger": ["command": executable, "args": [String]()]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}
