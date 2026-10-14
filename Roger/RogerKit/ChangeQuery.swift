import Foundation

/// One item in a `get_changes` answer, at its latest event in the range.
public struct ChangeEntry: Equatable, Sendable {
    public let seq: Int
    public let event: ChangeEventType
    public let kind: LibraryItemKind
    public let key: String
    public let title: String?
    public let date: Date?
    public let duration: Int?
    public let paths: [String]
    /// The event says the item exists, but its Markdown file is gone.
    public let missing: Bool
    /// The whole file; nil for `deleted`, `missing` and summaries.
    public let markdown: String?

    /// `==== roger entry <seq> ====`, TOON fields, then the Markdown after
    /// a blank line.
    public func render() -> String {
        var lines = [
            "==== roger entry \(seq) ====",
            TOON.field("seq", .int(seq)),
            TOON.field("event", .string(event.rawValue)),
            TOON.field("kind", .string(kind.rawValue)),
            TOON.field("key", .string(key)),
        ]
        if missing { lines.append(TOON.field("missing", .bool(true))) }
        if let title { lines.append(TOON.field("title", .string(title))) }
        if let date { lines.append(TOON.field("date", .string(RFC3339.string(date)))) }
        if event != .deleted, !missing { lines.append(TOON.field("duration", duration.map { .int($0) } ?? .null)) }
        if !paths.isEmpty { lines.append(TOON.inlineArray("paths", paths.map { .string($0) })) }
        var text = lines.joined(separator: "\n")
        if let markdown {
            var body = markdown
            while body.hasSuffix("\n") { body.removeLast() }
            text += "\n\n" + body
        }
        return text
    }
}

public struct ChangeAnswer: Equatable, Sendable {
    public let from: Int
    public let upTo: Int
    public let more: Bool
    public let entries: [ChangeEntry]

    /// TOON head (`from`, `upTo`, `more`, `count`), then the entries.
    public func render() -> String {
        let head = [
            TOON.field("from", .int(from)),
            TOON.field("upTo", .int(upTo)),
            TOON.field("more", .bool(more)),
            TOON.field("count", .int(entries.count)),
        ].joined(separator: "\n")
        return ([head] + entries.map { $0.render() }).joined(separator: "\n\n")
    }
}

/// `get_changes`: select the range, keep the latest event per key at that
/// event's position, filter by kind, read each item and cut at an item
/// boundary when the text passes the limit (a single entry above the limit
/// still comes whole).
public enum ChangeQuery {
    public static let textLimit = 30_000
    public static let summaryLimit = 45_000

    public static func run(
        events: [ChangeEvent],
        start: ChangeStart,
        kinds: Set<LibraryItemKind>?,
        summary: Bool,
        root: URL,
        limit: Int? = nil
    ) -> ChangeAnswer {
        let sorted = events.sorted { $0.seq < $1.seq }
        let lastSeq = sorted.last?.seq ?? 0
        let from: Int
        let end: Int
        switch start {
        case .afterSeq(let seq):
            from = seq + 1
            end = lastSeq
        case .atOrAfter(let date):
            from = sorted.first { $0.at >= date }?.seq ?? lastSeq + 1
            end = lastSeq
        case .range(let first, let last):
            from = first
            end = last
        }

        var latest: [String: ChangeEvent] = [:]
        for event in sorted where event.seq >= from && event.seq <= end {
            latest[event.key] = event
        }
        var grouped = latest.values.sorted { $0.seq < $1.seq }
        if let kinds { grouped = grouped.filter { kinds.contains($0.kind) } }

        let budget = limit ?? (summary ? summaryLimit : textLimit)
        var entries: [ChangeEntry] = []
        var used = 0
        var more = false
        for event in grouped {
            let entry = makeEntry(event, root: root, includeText: !summary)
            let size = entry.render().count
            if !entries.isEmpty, used + size > budget {
                more = true
                break
            }
            entries.append(entry)
            used += size
        }
        // An empty range answers with the position before it, capped at the
        // last seq, so a consumer never ends up ahead of the log.
        let upTo = more ? (entries.last?.seq ?? end) : (from > end ? min(from - 1, lastSeq) : end)
        return ChangeAnswer(from: from, upTo: upTo, more: more, entries: entries)
    }

    private static func makeEntry(_ event: ChangeEvent, root: URL, includeText: Bool) -> ChangeEntry {
        guard event.event != .deleted else {
            return ChangeEntry(seq: event.seq, event: event.event, kind: event.kind, key: event.key, title: nil, date: nil,
                               duration: nil, paths: [], missing: false, markdown: nil)
        }
        guard let item = ItemResolver.item(path: event.path, kind: event.kind, root: root) else {
            return ChangeEntry(seq: event.seq, event: event.event, kind: event.kind, key: event.key, title: nil, date: nil,
                               duration: nil, paths: [], missing: true, markdown: nil)
        }
        return ChangeEntry(
            seq: event.seq,
            event: event.event,
            kind: event.kind,
            key: event.key,
            title: item.title,
            date: item.date,
            duration: item.durationSeconds,
            paths: ItemResolver.paths(of: item),
            missing: false,
            markdown: includeText ? ItemResolver.markdown(of: item) : nil
        )
    }
}
