import MCP

/// Tool definitions and the server instructions. Text agents read: plain
/// sentences, no Oxford comma, no long dashes.
enum ToolCatalog {
    static let instructions = """
    Roger is a speech-to-text app on this Mac. Its library holds log entries, meeting transcripts and file transcripts as Markdown files.
    To ingest what is new, call get_changes with your consumer name, ingest each entry, then call ack with that consumer and the upTo and library from the answer. Repeat while more is true.
    Entries come one per item with its latest state. On updated read the item again as a whole. On deleted remove what you made from it.
    Answers are text. Lists are TOON: a header like items[3]{key,kind,title}: and then one comma-separated row per record. Values with commas, colons or quotes are in double quotes.
    A get_changes answer starts with from, upTo, more, count and library. Each entry then starts with the line ==== roger entry <seq> ====, lists its fields and has its Markdown after a blank line.
    Items are named by keys. No tool takes a file path and no tool deletes anything.
    """

    private static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    /// Claude Code keeps tool answers up to this size inline instead of
    /// moving them into a file. Without it the limit is 50,000 characters.
    private static let largeResult = Metadata(additionalFields: ["anthropic/maxResultSizeChars": .int(500_000)])

    private static let kindValues: Value = .array([.string("log"), .string("meeting"), .string("transcript")])

    static let tools: [Tool] = [
        Tool(
            name: "status",
            title: "Library status",
            description: "Shows the library folder, item counts per kind, the last change seq and every consumer with its bookmark, age and number of open changes.",
            inputSchema: schema([:]),
            annotations: readOnly
        ),
        Tool(
            name: "get_changes",
            title: "Get changes",
            description: "Returns what changed in the library, one entry per item with its latest state. Pass exactly one start: consumer (after that consumer's bookmark, unknown names start at 0), since (a seq, a date YYYY-MM-DD, an RFC 3339 time or a duration like 30m, 12h or 3d) or from with upTo (a fixed range). Ingest loop: call get_changes with your consumer, ingest every entry, then call ack with the same consumer and the answer's upTo and library. Repeat while more is true. With since, pass the previous upTo as since. On updated read the entry again as a whole. On deleted remove what you made from it. summary: true leaves out the Markdown, so you can plan first and then fetch groups with from and upTo (optionally with kinds). Only ack the upTo of a call without kinds.",
            inputSchema: schema([
                "consumer": property("string", "Your consumer name: a-z, 0-9 and -, at most 64 characters."),
                "since": property("string", "A seq like 42, a date YYYY-MM-DD, an RFC 3339 time or a duration like 30m, 12h or 3d."),
                "from": .object(["type": .string("integer"), "minimum": .int(1)]),
                "upTo": .object(["type": .string("integer"), "minimum": .int(1)]),
                "kinds": .object(["type": .string("array"), "items": .object(["type": .string("string"), "enum": kindValues])]),
                "summary": property("boolean", "Leave out the Markdown. Default false."),
            ]),
            annotations: readOnly,
            _meta: largeResult
        ),
        Tool(
            name: "ack",
            title: "Confirm ingested changes",
            description: "Moves a consumer's bookmark to upTo after you ingested everything up to it. Never moves it backwards: an older upTo leaves the bookmark as it is. upTo must not be after the last change. Pass the library from the get_changes answer: when Roger switched to another library since, ack refuses and changes nothing.",
            inputSchema: schema([
                "consumer": property("string", "Your consumer name."),
                "upTo": .object(["type": .string("integer"), "minimum": .int(0)]),
                "library": property("string", "The library value from the get_changes answer."),
            ], required: ["consumer", "upTo"]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_item",
            title: "Get item",
            description: "Returns one item by its key: the whole Markdown file, then its absolute file paths (Markdown, audio and meeting screenshots). Keys come from get_changes, list_items or search.",
            inputSchema: schema(["key": property("string", "An item key such as Logs/2026/10/2026-10-13 14-32-05.")], required: ["key"]),
            annotations: readOnly,
            _meta: largeResult
        ),
        Tool(
            name: "list_items",
            title: "List items",
            description: "Lists current items, newest first, with key, kind, title, date, duration in seconds and paths (several absolute paths separated by \" | \"). Optional kind, since (a date, an RFC 3339 time or a duration) and limit (default 50, at most 500).",
            inputSchema: schema([
                "kind": .object(["type": .string("string"), "enum": kindValues]),
                "since": property("string", "A date YYYY-MM-DD, an RFC 3339 time or a duration like 3d."),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(500)]),
            ]),
            annotations: readOnly
        ),
        Tool(
            name: "search",
            title: "Search",
            description: "Finds items whose title or text contains every word of the query, case-insensitive, newest first. Optional kind and limit (default 20, at most 100). Returns key, kind, title, date and a snippet.",
            inputSchema: schema([
                "query": property("string", "Words that must all appear."),
                "kind": .object(["type": .string("string"), "enum": kindValues]),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(100)]),
            ], required: ["query"]),
            annotations: readOnly
        ),
    ]
}
