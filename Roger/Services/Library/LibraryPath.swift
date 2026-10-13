import Foundation

/// Path helpers for the library index. FSEvents reports real paths
/// (`/private/var/...`), so every path the index stores or compares is
/// canonical: the `realpath` of its nearest existing ancestor plus the
/// parts below it that do not exist (yet or any more). Do not use
/// `resolvingSymlinksInPath()` here: it turns `/private/var` into `/var`.
enum LibraryPath {
    static func canonical(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path
        if let resolved = realpath(existing.path, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        return missing.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func canonicalURL(_ url: URL, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: canonical(url), isDirectory: isDirectory)
    }

    /// True when `path` is `folder` or lies below it.
    static func isPath(_ path: String, inside folder: String) -> Bool {
        if path == folder { return true }
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The components of `path` below `folder`; empty when they are equal
    /// or `path` is not inside `folder`.
    static func components(of path: String, below folder: String) -> [String] {
        guard isPath(path, inside: folder), path != folder else { return [] }
        let prefixLength = folder.hasSuffix("/") ? folder.count : folder.count + 1
        return path.dropFirst(prefixLength).split(separator: "/").map(String.init)
    }

    /// `url` itself or its nearest existing ancestor.
    static func nearestExisting(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}
