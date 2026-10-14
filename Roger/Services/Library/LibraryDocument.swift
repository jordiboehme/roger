import Foundation

/// A library file as read from disk for the detail pane, through
/// `TextFile` (UTF-8, LF). `frontmatter + body` is that text.
struct LibraryDocument: Equatable, Sendable {
    let url: URL
    /// Exact frontmatter text including both `---` lines; empty when the file has none.
    let frontmatter: String
    let body: String
    /// When the file was read; `saveBody` compares it to detect changes by other apps.
    let modificationDate: Date?

    static func load(_ url: URL) throws -> LibraryDocument {
        let text = try TextFile.read(url)
        let parts = LibraryFrontmatterParser.split(text)
        return LibraryDocument(
            url: url,
            frontmatter: parts.frontmatter.map(String.init) ?? "",
            body: String(parts.body),
            modificationDate: LibraryDocumentEditor.modificationDate(of: url)
        )
    }
}

/// Rename and body edits. File names never change: rename edits the
/// frontmatter `title` and the first H1, and nothing else.
enum LibraryDocumentEditor {
    enum SaveOutcome: Equatable, Sendable {
        case saved
        /// Another app changed the file after it was loaded. Nothing was written.
        case changedOnDisk
        /// The file is gone (moved or deleted). Nothing was written.
        case missing
    }

    enum RenameError: LocalizedError {
        case notRenamable

        var errorDescription: String? {
            "This file has no title or heading Roger can change."
        }
    }

    /// Read without URL resource caching, so a change by another app is seen.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// One line, trimmed. Nil when nothing is left.
    static func normalisedTitle(_ raw: String) -> String? {
        let single = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return single.isEmpty ? nil : single
    }

    /// `text` with the frontmatter `title` (added after `type:` when
    /// missing) and the first H1 set to `title`. Every other byte stays the
    /// same. Nil when the title is empty or the file has neither
    /// frontmatter nor an H1.
    static func renamed(_ text: String, to rawTitle: String) -> String? {
        guard let title = normalisedTitle(rawTitle) else { return nil }
        let parts = LibraryFrontmatterParser.split(text)
        let front = parts.frontmatter.map { replacingTitle(in: String($0), with: title) }
        let (body, hadHeading) = replacingHeading(in: String(parts.body), with: title)
        guard front != nil || hadHeading else { return nil }
        return (front ?? "") + body
    }

    static func rename(fileAt url: URL, to title: String) throws {
        guard let renamed = renamed(try TextFile.read(url), to: title) else {
            throw RenameError.notRenamable
        }
        try write(renamed, to: url)
    }

    /// Saves `body` under the file's current frontmatter. Refuses when the
    /// file changed since `document` was loaded (unless `overwrite`) or no
    /// longer exists. The frontmatter is read from disk at save time, so an
    /// overwrite never undoes a rename made in the meantime. Overwrite writes
    /// the caller's body as is, so an H1 renamed meanwhile is replaced by the
    /// body's H1 (the frontmatter title survives). The UI disables rename
    /// while editing. The body's line endings become LF.
    static func saveBody(_ body: String, of document: LibraryDocument, overwrite: Bool = false) throws -> SaveOutcome {
        let url = document.url
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if !overwrite, modificationDate(of: url) != document.modificationDate { return .changedOnDisk }
        let current = try LibraryDocument.load(url)
        try write(current.frontmatter + TextFile.normalizeLineEndings(body), to: url)
        return .saved
    }

    /// Writes into a scratch folder on the same volume and swaps the file
    /// in with `replaceItemAt`, which keeps the original's creation date,
    /// Finder tags and other attributes. The original is never truncated in
    /// place, so a failed write leaves it intact.
    static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(url.lastPathComponent)
        try Data(text.utf8).write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp)
    }

    /// False for an unfinished meeting without a transcript and for files
    /// in the session folder of a meeting that is being recorded or
    /// finalised.
    static func canEdit(_ item: LibraryItem, activeSessionFolder: URL?) -> Bool {
        guard item.hasMarkdown else { return false }
        guard let activeSessionFolder else { return true }
        return !LibraryPath.isPath(LibraryPath.canonical(item.url), inside: LibraryPath.canonical(activeSessionFolder))
    }

    // MARK: - Helpers

    private static func replacingTitle(in frontmatter: String, with title: String) -> String {
        var lines = frontmatter.components(separatedBy: "\n")
        let line = "title: " + TranscriptFrontmatter.quoted(title)
        if let index = lines.firstIndex(where: { $0.hasPrefix("title:") }) {
            lines[index] = line
        } else if let index = lines.firstIndex(where: { $0.hasPrefix("type:") }) {
            lines.insert(line, at: index + 1)
        } else {
            lines.insert(line, at: 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func replacingHeading(in body: String, with title: String) -> (String, Bool) {
        var lines = body.components(separatedBy: "\n")
        var fence: Character?
        var found: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.hasPrefix(String(repeating: marker, count: 3)) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            if fence == nil, line.hasPrefix("# ") { found = i; break }
        }
        guard let index = found else { return (body, false) }
        lines[index] = "# " + title
        return (lines.joined(separator: "\n"), true)
    }
}
