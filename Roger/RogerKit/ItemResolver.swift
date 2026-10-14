import Foundation

public enum ItemKeyError: Error, Equatable, LocalizedError {
    case invalid(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let key):
            return "\"\(key)\" is not a valid key. Use a key from get_changes, list_items or search."
        case .notFound(let key):
            return "No item with the key \"\(key)\"."
        }
    }
}

/// Turns change-log paths and tool keys into items on disk. Keys never
/// leave the library: they are relative, have no `.`, `..` or empty parts,
/// no hidden parts and resolve (after symlinks) inside the root. `External/`
/// keys are only valid when the change log knows them.
public enum ItemResolver {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    /// `path` from an event: relative to the root, or absolute for `External/` keys.
    public static func markdownURL(path: String, root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// The item as it is on disk now. Nil when the Markdown file is gone.
    public static func item(path: String, kind: LibraryItemKind, root: URL) -> LibraryItem? {
        let url = markdownURL(path: path, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let folder = (kind == .meeting && url.lastPathComponent == "transcript.md") ? url.deletingLastPathComponent() : nil
        guard var item = LibraryItemReader.item(markdownAt: url, fallbackKind: kind, folder: folder) else { return nil }
        item.kind = kind
        return item
    }

    /// Absolute paths: the Markdown file, its audio (a file transcript's
    /// source media included) and, for meetings, the screenshots in the
    /// session folder, sorted by name.
    public static func paths(of item: LibraryItem) -> [String] {
        var result = [LibraryPath.canonical(item.url)]
        result += item.audioFiles.map { LibraryPath.canonical($0) }
        if item.kind == .meeting {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: item.folderURL.path)) ?? []
            result += names
                .filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
                .map { LibraryPath.canonical(item.folderURL.appendingPathComponent($0)) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// The whole file as text; nil when it cannot be read as UTF-8.
    public static func markdown(of item: LibraryItem) -> String? {
        (try? Data(contentsOf: item.url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The item behind a key passed to a tool.
    public static func subject(forKey key: String, root: URL, events: [ChangeEvent]) throws -> ChangeSubject {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard !key.isEmpty,
              !key.hasPrefix("/"),
              !key.hasPrefix("~"),
              !key.contains("\\"),
              !key.contains("\0"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") })
        else { throw ItemKeyError.invalid(key) }

        if key.hasPrefix(ChangeKey.externalPrefix) {
            guard let last = ChangeLog.lastEvents(events)[key], last.event != .deleted else { throw ItemKeyError.notFound(key) }
            return ChangeSubject(kind: last.kind, key: key, path: last.path)
        }

        let rootPath = LibraryPath.canonical(root)
        let base = URL(fileURLWithPath: rootPath, isDirectory: true)
        let candidates: [(URL, LibraryItemKind)] = [
            (base.appendingPathComponent(key + ".md"), key.hasPrefix("Logs/") ? .log : .transcript),
            (base.appendingPathComponent(key, isDirectory: true).appendingPathComponent("transcript.md"), .meeting),
        ]
        for (url, fallback) in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard LibraryPath.isPath(LibraryPath.canonical(url), inside: rootPath) else { throw ItemKeyError.invalid(key) }
            guard let item = LibraryItemReader.item(markdownAt: url, fallbackKind: fallback) else { continue }
            let kind: LibraryItemKind = url.lastPathComponent == "transcript.md" && fallback == .meeting ? .meeting : item.kind
            return ChangeKey.subject(markdownURL: url, kind: kind, root: root)
        }
        throw ItemKeyError.notFound(key)
    }
}
