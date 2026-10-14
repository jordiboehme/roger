import CryptoKit
import Foundation

/// What the change log says about one item.
public struct ChangeSubject: Equatable, Sendable {
    public let kind: LibraryItemKind
    public let key: String
    public let path: String

    public init(kind: LibraryItemKind, key: String, path: String) {
        self.kind = kind
        self.key = key
        self.path = path
    }

    public var isExternal: Bool { key.hasPrefix(ChangeKey.externalPrefix) }
}

/// Stable item ids. Under `Logs/`, `Meetings/` or `Transcripts/` of the
/// library: the library-relative path without `.md` (meetings: the session
/// folder), and `path` is the relative path of the Markdown file. Anywhere
/// else (transcripts next to their source, items in extra scan folders,
/// also when those are inside the library folder): `External/<name>-<hash8>`
/// with the canonical absolute path. All paths are canonical
/// (`LibraryPath`), so `/var/...` and `/private/var/...` give the same key.
public enum ChangeKey {
    public static let externalPrefix = "External/"
    /// The library folders whose items get relative keys. `ItemResolver`
    /// resolves relative keys only below these.
    public static let libraryFolders: Set<String> = ["Logs", "Meetings", "Transcripts"]

    /// Nil for items without Markdown (unfinished meetings).
    public static func subject(for item: LibraryItem, root: URL) -> ChangeSubject? {
        guard item.hasMarkdown else { return nil }
        return subject(markdownURL: item.url, kind: item.kind, root: root)
    }

    public static func subject(markdownURL: URL, kind: LibraryItemKind, root: URL) -> ChangeSubject {
        let rootPath = LibraryPath.canonical(root)
        let markdown = LibraryPath.canonical(markdownURL)
        let isSession = kind == .meeting && markdownURL.lastPathComponent == "transcript.md"
        let subjectPath = isSession ? (markdown as NSString).deletingLastPathComponent : markdown

        let components = LibraryPath.components(of: subjectPath, below: rootPath)
        if components.count >= 2, libraryFolders.contains(components[0]) {
            let relativeSubject = components.joined(separator: "/")
            return ChangeSubject(
                kind: kind,
                key: isSession ? relativeSubject : withoutMarkdownExtension(relativeSubject),
                path: LibraryPath.components(of: markdown, below: rootPath).joined(separator: "/")
            )
        }
        let name = isSession
            ? (subjectPath as NSString).lastPathComponent
            : withoutMarkdownExtension((markdown as NSString).lastPathComponent)
        return ChangeSubject(kind: kind, key: externalKey(name: name, absolutePath: subjectPath), path: markdown)
    }

    /// `External/<name>-<first 8 hex of SHA-256(absolutePath)>`.
    public static func externalKey(name: String, absolutePath: String) -> String {
        let hex = SHA256.hash(data: Data(absolutePath.utf8)).map { String(format: "%02x", $0) }.joined()
        return externalPrefix + name + "-" + hex.prefix(8)
    }

    private static func withoutMarkdownExtension(_ path: String) -> String {
        path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
    }
}
