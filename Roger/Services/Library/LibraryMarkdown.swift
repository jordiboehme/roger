import Foundation
import SwiftUI

/// One block of the simple Markdown preview.
enum LibraryMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Consecutive non-empty lines, joined with line breaks kept.
    case paragraph(String)
    /// A local image on a line of its own (meeting screenshots).
    case image(alt: String, url: URL)
}

/// The preview's Markdown: headings, paragraphs with inline bold and
/// italics, and local images. Not a full CommonMark renderer.
enum LibraryMarkdown {
    static func blocks(from body: String, baseURL: URL) -> [LibraryMarkdownBlock] {
        var blocks: [LibraryMarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let heading = heading(line) {
                flush()
                blocks.append(heading)
            } else if let image = image(line, baseURL: baseURL) {
                flush()
                blocks.append(image)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// `# Title` up to `###### Title`; a space after the hashes is required.
    static func heading(_ line: String) -> LibraryMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    /// `![alt](target)` alone on a line with a local target. Roger writes
    /// targets percent-encoded (spaces as `%20`).
    static func image(_ line: String, baseURL: URL) -> LibraryMarkdownBlock? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        let target = String(line[close.upperBound..<line.index(before: line.endIndex)])
        guard !target.contains("://"), let decoded = target.removingPercentEncoding, !decoded.isEmpty else { return nil }
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appendingPathComponent(decoded)
        return .image(alt: alt, url: url.standardizedFileURL)
    }

    /// Every case-insensitive occurrence of each term, in text order.
    static func highlightRanges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text.range(of: term, options: .caseInsensitive, range: start..<text.endIndex) {
                ranges.append(found)
                start = found.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Inline Markdown (bold, italics, code) with search matches highlighted.
    static func attributed(_ text: String, highlighting terms: [String]) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let plain = String(result.characters)
        for range in highlightRanges(of: terms, in: plain) {
            let offset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let start = result.characters.index(result.startIndex, offsetBy: offset)
            let end = result.characters.index(start, offsetBy: length)
            // Explicit keys: AppKit and SwiftUI both define these attributes.
            result[start..<end][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.yellow.opacity(0.45)
            result[start..<end][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.black
        }
        return result
    }
}
