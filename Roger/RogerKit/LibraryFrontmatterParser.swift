import Foundation

/// The parts of a Roger Markdown file's frontmatter the library needs.
public struct LibraryFrontmatter: Equatable, Sendable {
    public struct Source: Equatable, Sendable {
        public let id: String
        public let resource: String

        public init(id: String, resource: String) {
            self.id = id
            self.resource = resource
        }
    }

    /// Top-level `key: value` lines with the value unquoted. Inline maps
    /// such as `generated` keep their raw `{ ... }` text.
    public var scalars: [String: String] = [:]
    public var tags: [String] = []
    public var sources: [Source] = []

    public init(scalars: [String: String] = [:], tags: [String] = [], sources: [Source] = []) {
        self.scalars = scalars
        self.tags = tags
        self.sources = sources
    }
}

/// Reads the frontmatter `TranscriptFrontmatter` writes: top-level scalars
/// (plain, double-quoted or single-quoted), `tags` as `[a, b]` or a block
/// list, and `sources` as a block list of inline maps. Not a general YAML
/// parser.
public enum LibraryFrontmatterParser {
    /// Splits `text` into the frontmatter block (the opening `---` line up to
    /// and including the closing `---` line) and the rest, so that
    /// `frontmatter + body == text`. No frontmatter when the text does not
    /// start with `---\n` or the block is never closed.
    public static func split(_ text: String) -> (frontmatter: Substring?, body: Substring) {
        guard text.hasPrefix("---\n") else { return (nil, text[...]) }
        let searchStart = text.index(text.startIndex, offsetBy: 3)
        if let close = text.range(of: "\n---\n", range: searchStart..<text.endIndex) {
            return (text[..<close.upperBound], text[close.upperBound...])
        }
        if text.hasSuffix("\n---") {
            return (text[...], text[text.endIndex...])
        }
        return (nil, text[...])
    }

    public static func parse(_ text: String) -> LibraryFrontmatter? {
        guard let block = split(text).frontmatter else { return nil }
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeFirst()
        if lines.last == "" { lines.removeLast() }
        if lines.last == "---" { lines.removeLast() }

        var result = LibraryFrontmatter()
        var listKey: String?
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("-") {
                let entry = line.trimmingCharacters(in: .whitespaces)
                guard entry.hasPrefix("-"), let key = listKey else { continue }
                let value = entry.dropFirst().trimmingCharacters(in: .whitespaces)
                if key == "tags" {
                    result.tags.append(unquote(value))
                } else if key == "sources" {
                    let map = inlineMap(value)
                    if let id = map["id"], let resource = map["resource"] {
                        result.sources.append(.init(id: id, resource: resource))
                    }
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                listKey = nil
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            listKey = value.isEmpty ? key : nil
            if key == "tags", value.hasPrefix("[") {
                result.tags = flowList(value)
            } else if !value.isEmpty {
                result.scalars[key] = value.hasPrefix("{") ? value : unquote(value)
            }
        }
        return result
    }

    /// Undoes `TranscriptFrontmatter.quoted`: `\"`, `\\`, `\n`, `\r`, `\t`
    /// and `\uXXXX`. Single-quoted values lose their quotes (`''` is `'`).
    /// Anything else is returned trimmed.
    public static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var out = ""
        var scalars = String(value.dropFirst().dropLast()).unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            guard let next = scalars.next() else {
                out.append("\\")
                break
            }
            switch next {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    if let digit = scalars.next() { hex.unicodeScalars.append(digit) }
                }
                if let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) {
                    out.unicodeScalars.append(decoded)
                } else {
                    out += "\\u" + hex
                }
            default:
                out.append("\\")
                out.unicodeScalars.append(next)
            }
        }
        return out
    }

    /// `{ id: audio, resource: "a.m4a" }` as a dictionary with unquoted
    /// values. Only the first `:` of each entry separates key and value.
    public static func inlineMap(_ raw: String) -> [String: String] {
        var inner = raw.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("{") { inner.removeFirst() }
        if inner.hasSuffix("}") { inner.removeLast() }
        var map: [String: String] = [:]
        for part in splitOutsideQuotes(inner, separator: ",") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            let value = String(part[part.index(after: colon)...])
            if !key.isEmpty { map[key] = unquote(value) }
        }
        return map
    }

    /// `[a, "b, c"]` as `["a", "b, c"]`.
    private static func flowList(_ raw: String) -> [String] {
        var inner = raw.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        return splitOutsideQuotes(inner, separator: ",").map(unquote).filter { !$0.isEmpty }
    }

    private static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == separator && !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
