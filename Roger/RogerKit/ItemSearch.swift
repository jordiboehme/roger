import Foundation

public struct SearchHit: Equatable, Sendable {
    public let item: LibraryItem
    public let snippet: String
}

/// `search`: a case-insensitive scan over title and body of every item with
/// Markdown. Every word must match. Newest first. No index (same reasoning
/// as the library window).
public enum ItemSearch {
    /// The most characters a snippet has, "..." markers included.
    public static let snippetLength = 160
    private static let marker = "..."
    private static let leadingContext = 60

    public static func search(_ query: String, in items: [LibraryItem], kind: LibraryItemKind?, limit: Int) -> [SearchHit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        return items
            .filter { item in
                item.hasMarkdown
                    && (kind == nil || item.kind == kind)
                    && words.allSatisfy { item.searchText.contains($0) }
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { SearchHit(item: $0, snippet: snippet(for: $0, words: words)) }
    }

    /// At most `snippetLength` characters of the body around the first match,
    /// whitespace folded to single spaces, with "..." where text was cut.
    public static func snippet(for item: LibraryItem, words: [String]) -> String {
        let body = ItemResolver.markdown(of: item).map { String(LibraryFrontmatterParser.split($0).body) } ?? item.firstLine
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let first = words
            .compactMap { flat.range(of: $0, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let first else { return String(flat.prefix(snippetLength)) }
        // Room for a marker at each end, so the total never passes the limit.
        let window = snippetLength - 2 * marker.count
        let start = flat.index(first.lowerBound, offsetBy: -leadingContext, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: window, limitedBy: flat.endIndex) ?? flat.endIndex
        var snippet = String(flat[start..<end])
        if start > flat.startIndex { snippet = marker + snippet }
        if end < flat.endIndex { snippet += marker }
        return snippet
    }
}
