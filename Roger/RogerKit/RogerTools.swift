import Foundation

/// The six tools. Every call finds the library again (see
/// `LibraryLocator`). Only `ack` writes, and only a bookmark file.
public struct RogerTools: Sendable {
    public static let names = ["status", "get_changes", "ack", "get_item", "list_items", "search"]

    private let locator: LibraryLocator
    private let registry: ExternalTranscriptRegistry
    private let now: @Sendable () -> Date

    public init(locator: LibraryLocator, registry: ExternalTranscriptRegistry, now: @escaping @Sendable () -> Date = { Date() }) {
        self.locator = locator
        self.registry = registry
        self.now = now
    }

    public func call(_ name: String, arguments: [String: ToolValue]) -> ToolOutput {
        let location = locator.locate()
        let args = ToolArguments(values: arguments)
        do {
            switch name {
            case "status":
                return .ok(status(location))
            case "get_changes":
                try requireReady(location)
                return .ok(try getChanges(args, location))
            case "ack":
                try requireReady(location)
                return .ok(try ack(args, location))
            case "get_item":
                try requireReady(location)
                return .ok(try getItem(args, location))
            case "list_items":
                try requireReady(location)
                return .ok(try listItems(args, location))
            case "search":
                try requireReady(location)
                return .ok(try search(args, location))
            default:
                return .error("Unknown tool \"\(name)\".")
            }
        } catch let failure as ToolFailure {
            return .error(failure.message)
        } catch let keyError as ItemKeyError {
            return .error(keyError.localizedDescription)
        } catch let nameError as ConsumerBookmarkError {
            return .error(nameError.localizedDescription)
        } catch {
            // Anything else is unexpected (a file system error): say which
            // tool and which library, so the agent can tell the user.
            return .error("\(name) failed in the library at \(location.root.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Tools

    private func status(_ location: LibraryLocation) -> String {
        var lines = [TOON.field("library", .string(location.root.path))]
        if let message = LibraryLocator.accessMessage(location.access, root: location.root) {
            lines.append(TOON.field("state", .string(location.access == .notSetUp ? "not set up" : "not readable")))
            lines.append(TOON.field("message", .string(message)))
            return lines.joined(separator: "\n")
        }
        let events: [ChangeEvent]
        do {
            events = try ChangeLogFile.readEvents(root: location.root)
        } catch {
            // Not "ready, 0 events": the agent must know the log is unreadable.
            let path = ChangeLogFile.url(root: location.root).path
            lines.append(TOON.field("state", .string("not readable")))
            lines.append(TOON.field("message", .string("Roger cannot read the change log at \(path): \(error.localizedDescription)")))
            return lines.joined(separator: "\n")
        }
        let lastSeq = events.map(\.seq).max() ?? 0
        lines.append(TOON.field("state", .string("ready")))
        lines.append(TOON.field("lastSeq", .int(lastSeq)))
        lines.append(TOON.field("lastEventAt", events.last.map { .string(RFC3339.string($0.at)) } ?? .null))
        let items = currentItems(location)
        lines.append(TOON.object("items"))
        for kind in LibraryItemKind.allCases {
            lines.append(TOON.field(kind.rawValue, .int(items.filter { $0.kind == kind }.count), depth: 1))
        }
        let rows: [[TOONValue]] = ConsumerBookmarks(root: location.root).all().map { named in
            [
                .string(named.name),
                .int(named.bookmark.seq),
                .string(RFC3339.string(named.bookmark.updatedAt)),
                .string(Self.age(from: named.bookmark.updatedAt, to: now())),
                .int(events.filter { $0.seq > named.bookmark.seq }.count),
            ]
        }
        lines.append(TOON.table("consumers", fields: ["name", "seq", "updatedAt", "age", "open"], rows: rows))
        return lines.joined(separator: "\n")
    }

    private func getChanges(_ args: ToolArguments, _ location: LibraryLocation) throws -> String {
        let consumer = try args.string("consumer")
        let hasSince = args.has("since")
        let from = try args.int("from")
        let upTo = try args.int("upTo")
        if (from == nil) != (upTo == nil) {
            throw ToolFailure("Pass from and upTo together.")
        }
        let forms = [consumer != nil, hasSince, from != nil].filter { $0 }.count
        guard forms == 1 else {
            throw ToolFailure("Pass exactly one start: consumer, since or from with upTo.")
        }
        let kinds: Set<LibraryItemKind>? = try args.strings("kinds").map { names in
            Set(try names.map { name in
                guard let kind = LibraryItemKind(rawValue: name) else {
                    throw ToolFailure("kinds takes log, meeting and transcript.")
                }
                return kind
            })
        }
        let summary = try args.bool("summary") ?? false
        let events = try ChangeLogFile.readEvents(root: location.root)
        let lastSeq = events.map(\.seq).max() ?? 0

        let start: ChangeStart
        if let consumer {
            let bookmark = try ConsumerBookmarks(root: location.root).bookmark(consumer)
            start = .afterSeq(bookmark?.seq ?? 0)
        } else if hasSince {
            guard let raw = try args.sinceText("since"), let parsed = SinceParser.parse(raw, now: now()) else {
                throw ToolFailure("since takes a seq, a date (YYYY-MM-DD), an RFC 3339 time or a duration like 30m, 12h or 3d.")
            }
            start = parsed
        } else if let from, let upTo {
            guard from >= 1, from <= upTo, upTo <= lastSeq else {
                throw ToolFailure("from and upTo must satisfy 1 <= from <= upTo <= \(lastSeq).")
            }
            start = .range(from: from, upTo: upTo)
        } else {
            throw ToolFailure("Pass exactly one start: consumer, since or from with upTo.")
        }
        return ChangeQuery.run(events: events, start: start, kinds: kinds, summary: summary, root: location.root)
            .render(library: LibraryPath.canonical(location.root))
    }

    private func ack(_ args: ToolArguments, _ location: LibraryLocation) throws -> String {
        guard let consumer = try args.string("consumer"), let upTo = try args.int("upTo") else {
            throw ToolFailure("ack needs consumer and upTo.")
        }
        // The library from get_changes: when Roger switched to another
        // library since, this upTo belongs to the old one.
        if let raw = try args.string("library") {
            let library = Self.unquotedTOON(raw)
            let given = URL(fileURLWithPath: (library as NSString).expandingTildeInPath, isDirectory: true)
            guard LibraryPath.canonical(given) == LibraryPath.canonical(location.root) else {
                throw ToolFailure("The library changed since get_changes. Call get_changes again.")
            }
        }
        let lastSeq = try ChangeLogFile.readEvents(root: location.root).map(\.seq).max() ?? 0
        guard upTo >= 0 else { throw ToolFailure("upTo must be 0 or more.") }
        guard upTo <= lastSeq else {
            throw ToolFailure("upTo \(upTo) is after the last change (\(lastSeq)).")
        }
        let result = try ConsumerBookmarks(root: location.root).ack(consumer, upTo: upTo, now: now())
        if result.current == upTo, result.previous < upTo {
            return "Bookmark \(consumer) is now \(result.current) (was \(result.previous))."
        }
        return "Bookmark \(consumer) stays at \(result.current). upTo \(upTo) is not newer."
    }

    /// get_changes quotes a library path with `:`, `,`, `[` and the like.
    /// A client may pass that value back verbatim: drop the quotes and undo
    /// the `\\` and `\"` escapes.
    static func unquotedTOON(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var out = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                if character != "\\", character != "\"" { out.append("\\") }
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private func getItem(_ args: ToolArguments, _ location: LibraryLocation) throws -> String {
        guard let key = try args.string("key") else { throw ToolFailure("get_item needs a key.") }
        let events = try ChangeLogFile.readEvents(root: location.root)
        let subject = try ItemResolver.subject(forKey: key, root: location.root, events: events)
        guard let item = ItemResolver.item(path: subject.path, kind: subject.kind, root: location.root),
              var markdown = ItemResolver.markdown(of: item)
        else { throw ItemKeyError.notFound(key) }
        while markdown.hasSuffix("\n") { markdown.removeLast() }
        let paths = ItemResolver.paths(of: item).map { TOONValue.string($0) }
        return markdown + "\n\n==== roger paths ====\n" + TOON.inlineArray("paths", paths)
    }

    private func listItems(_ args: ToolArguments, _ location: LibraryLocation) throws -> String {
        let kind = try kindArgument(args)
        var since: Date?
        if let raw = try args.sinceText("since") {
            guard case .atOrAfter(let date)? = SinceParser.parse(raw, now: now()) else {
                throw ToolFailure("since takes a date (YYYY-MM-DD), an RFC 3339 time or a duration like 30m, 12h or 3d here.")
            }
            since = date
        }
        let limit = try limitArgument(args, default: 50, max: 500)
        let items = currentItems(location)
            .filter { kind == nil || $0.kind == kind }
            .filter { since == nil || $0.date >= since! }
            .sorted { $0.date > $1.date }
            .prefix(limit)
        let rows: [[TOONValue]] = items.compactMap { item in
            guard let subject = ChangeKey.subject(for: item, root: location.root) else { return nil }
            return [
                .string(subject.key),
                .string(item.kind.rawValue),
                .string(item.title),
                .string(RFC3339.string(item.date)),
                item.durationSeconds.map { .int($0) } ?? .null,
                .string(ItemResolver.paths(of: item).joined(separator: " | ")),
            ]
        }
        return TOON.table("items", fields: ["key", "kind", "title", "date", "duration", "paths"], rows: rows)
    }

    private func search(_ args: ToolArguments, _ location: LibraryLocation) throws -> String {
        guard let query = try args.string("query"), !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolFailure("search needs a query.")
        }
        let kind = try kindArgument(args)
        let limit = try limitArgument(args, default: 20, max: 100)
        let rows: [[TOONValue]] = ItemSearch.search(query, in: currentItems(location), kind: kind, limit: limit).compactMap { hit in
            guard let subject = ChangeKey.subject(for: hit.item, root: location.root) else { return nil }
            return [
                .string(subject.key),
                .string(hit.item.kind.rawValue),
                .string(hit.item.title),
                .string(RFC3339.string(hit.item.date)),
                .string(hit.snippet),
            ]
        }
        return TOON.table("results", fields: ["key", "kind", "title", "date", "snippet"], rows: rows)
    }

    // MARK: - Helpers

    private func requireReady(_ location: LibraryLocation) throws {
        if let message = LibraryLocator.accessMessage(location.access, root: location.root) {
            throw ToolFailure(message)
        }
    }

    /// Every item with Markdown, from the library, the extra folders and
    /// (with Roger's settings) the external transcripts.
    private func currentItems(_ location: LibraryLocation) -> [LibraryItem] {
        LibraryScanner.scanAll(
            scope: LibraryScanScope(layout: LibraryLayout(root: location.root), extraFolders: location.extraFolders),
            externalFiles: location.usesRogerSettings ? registry.listedFiles() : []
        ).filter(\.hasMarkdown)
    }

    private func kindArgument(_ args: ToolArguments) throws -> LibraryItemKind? {
        guard let raw = try args.string("kind") else { return nil }
        guard let kind = LibraryItemKind(rawValue: raw) else {
            throw ToolFailure("kind takes log, meeting or transcript.")
        }
        return kind
    }

    private func limitArgument(_ args: ToolArguments, default fallback: Int, max maximum: Int) throws -> Int {
        guard let limit = try args.int("limit") else { return fallback }
        guard limit >= 1 else { throw ToolFailure("limit must be 1 or more.") }
        return min(limit, maximum)
    }

    /// `45m`, `3h`, `2d`.
    static func age(from date: Date, to now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
    }
}
