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

/// Stable item ids. Inside the library: the library-relative path without
/// `.md` (meetings: the session folder), and `path` is the relative path of
/// the Markdown file. Outside the library (transcripts next to their
/// source, items in extra scan folders): `External/<name>-<hash8>` with the
/// canonical absolute path. All paths are canonical (`LibraryPath`), so
/// `/var/...` and `/private/var/...` give the same key.
public enum ChangeKey {
    public static let externalPrefix = "External/"

    /// Nil for items without Markdown (unfinished meetings).
    public static func subject(for item: LibraryItem, root: URL) -> ChangeSubject? {
        guard item.hasMarkdown else { return nil }
        return subject(markdownURL: item.url, kind: item.kind, root: root)
    }

    public static func subject(markdownURL: URL, kind: LibraryItemKind, root: URL) -> ChangeSubject {
        let rootPath = LibraryPath.canonical(root)
        let rogerPath = LibraryPath.canonical(ChangeLogFile.folder(root: root))
        let markdown = LibraryPath.canonical(markdownURL)
        let isSession = kind == .meeting && markdownURL.lastPathComponent == "transcript.md"
        let subjectPath = isSession ? (markdown as NSString).deletingLastPathComponent : markdown

        if subjectPath != rootPath,
           LibraryPath.isPath(subjectPath, inside: rootPath),
           !LibraryPath.isPath(subjectPath, inside: rogerPath) {
            let relativeMarkdown = LibraryPath.components(of: markdown, below: rootPath).joined(separator: "/")
            let relativeSubject = LibraryPath.components(of: subjectPath, below: rootPath).joined(separator: "/")
            return ChangeSubject(
                kind: kind,
                key: isSession ? relativeSubject : withoutMarkdownExtension(relativeSubject),
                path: relativeMarkdown
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
