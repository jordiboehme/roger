import Foundation

public enum ChangeEventType: String, Codable, Sendable, CaseIterable {
    case created
    case updated
    case deleted
}

/// One line of `.roger/changes.jsonl`.
public struct ChangeEvent: Equatable, Sendable {
    public let seq: Int
    public let at: Date
    public let event: ChangeEventType
    public let kind: LibraryItemKind
    /// Stable item id (see `ChangeKey`).
    public let key: String
    /// Main Markdown file: library-relative, or absolute for `External/` keys.
    public let path: String

    public init(seq: Int, at: Date, event: ChangeEventType, kind: LibraryItemKind, key: String, path: String) {
        self.seq = seq
        self.at = at
        self.event = event
        self.kind = kind
        self.key = key
        self.path = path
    }

    /// One JSON object in the spec's field order, without a newline.
    /// `at` has whole seconds, so `parse(jsonLine())` gives back an equal
    /// event only for whole-second dates (Roger's clock values are
    /// truncated by RFC 3339 anyway).
    public func jsonLine(timeZone: TimeZone = .current) -> String {
        "{\"seq\":\(seq),\"at\":\(Self.json(RFC3339.string(at, timeZone: timeZone))),\"event\":\(Self.json(event.rawValue)),\"kind\":\(Self.json(kind.rawValue)),\"key\":\(Self.json(key)),\"path\":\(Self.json(path))}"
    }

    /// Made once: `parse` runs for every line of the log.
    private static let decoder = JSONDecoder()

    /// Nil for anything that is not a complete, valid event.
    public static func parse(_ line: Data) -> ChangeEvent? {
        guard let raw = try? decoder.decode(Raw.self, from: line),
              raw.seq >= 1,
              !raw.key.isEmpty,
              let at = RFC3339.date(raw.at),
              let event = ChangeEventType(rawValue: raw.event),
              let kind = LibraryItemKind(rawValue: raw.kind)
        else { return nil }
        return ChangeEvent(seq: raw.seq, at: at, event: event, kind: kind, key: raw.key, path: raw.path)
    }

    private struct Raw: Decodable {
        let seq: Int
        let at: String
        let event: String
        let kind: String
        let key: String
        let path: String
    }

    private static func json(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let quoted = String(data: data, encoding: .utf8) else { return "\"\"" }
        return quoted
    }
}

/// A change to append; the log assigns `seq` and `at`.
public struct PendingChange: Equatable, Sendable {
    public let event: ChangeEventType
    public let kind: LibraryItemKind
    public let key: String
    public let path: String

    public init(event: ChangeEventType, kind: LibraryItemKind, key: String, path: String) {
        self.event = event
        self.kind = kind
        self.key = key
        self.path = path
    }
}
