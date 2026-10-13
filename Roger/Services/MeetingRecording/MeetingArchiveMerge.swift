import Foundation

/// Handles a session folder that has both an archive (`mic.m4a`) and CAF
/// chunks, e.g. after a crash while chunks were being deleted. The chunks
/// are encoded to a side file and neither file is ever overwritten or
/// deleted: the longer one becomes the archive, the other stays next to it.
enum MeetingArchiveMerge {
    /// `<stem>.<label>.<ext>`, then `<stem>.<label> 1.<ext>` … until free.
    static func uniqueSibling(of archive: URL, label: String) -> URL {
        let folder = archive.deletingLastPathComponent()
        let stem = archive.deletingPathExtension().lastPathComponent
        let ext = archive.pathExtension
        var candidate = folder.appendingPathComponent("\(stem).\(label).\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem).\(label) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    /// Moves `url` to its first free `<stem>.<label>.<ext>` sibling
    /// (`<stem>.<label> 1.<ext>` …) and returns where it went. Never
    /// overwrites: `moveItem` fails rather than replace an existing file.
    /// The one helper for `transcript.previous.md`, segment
    /// `<name>.previous.md` files and `mic.previous.m4a` style archives.
    @discardableResult
    static func moveAside(_ url: URL, label: String = "previous") throws -> URL {
        let target = uniqueSibling(of: url, label: label)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Where the chunks are encoded when `archive` already exists.
    static func leftoverURL(for archive: URL) -> URL {
        uniqueSibling(of: archive, label: "leftover")
    }

    /// With `keepEncoded`, moves the old archive aside to
    /// `<stem>.previous.m4a` and the encoded file into its place. Without it,
    /// leaves both files where they are. Never deletes or overwrites a file;
    /// if the second move fails, the old archive is moved back.
    static func settle(archive: URL, encoded: URL, keepEncoded: Bool) throws {
        guard keepEncoded else { return }
        let fm = FileManager.default
        let previous = try moveAside(archive)
        do {
            try fm.moveItem(at: encoded, to: archive)
        } catch {
            try? fm.moveItem(at: previous, to: archive)
            throw error
        }
    }
}
