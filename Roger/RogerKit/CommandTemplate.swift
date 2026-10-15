import Foundation

/// The library item a command runs for, as the placeholders see it.
public struct CommandItemInfo: Equatable, Sendable {
    public let file: String
    public let key: String
    public let title: String
    public let kind: String

    public init(file: String, key: String, title: String, kind: String) {
        self.file = file
        self.key = key
        self.title = title
        self.kind = kind
    }
}

/// Fills a command's prompt and command line. Placeholders are replaced in
/// one pass, so text inside a value is never expanded again.
public enum CommandTemplate {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func renderPrompt(_ prompt: String, item: CommandItemInfo) -> String {
        substitute(prompt, values: itemValues(item))
    }

    public static func renderCommandLine(_ line: String, prompt: String, item: CommandItemInfo) -> String {
        var values = itemValues(item).mapValues(shellQuote)
        values["prompt"] = shellQuote(prompt)
        return substitute(line, values: values)
    }

    private static func itemValues(_ item: CommandItemInfo) -> [String: String] {
        ["file": item.file, "key": item.key, "title": item.title, "kind": item.kind]
    }

    /// Scans once from left to right. `{name}` with a known name is replaced,
    /// anything else is copied as it is.
    private static func substitute(_ text: String, values: [String: String]) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"),
               let value = values[String(rest[afterOpen..<close])] {
                out += value
                rest = rest[rest.index(after: close)...]
            } else {
                out += "{"
                rest = rest[afterOpen...]
            }
        }
        out += rest
        return out
    }
}
