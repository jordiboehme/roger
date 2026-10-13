import Foundation

/// Handles a session folder that has both an archive (`mic.m4a`) and CAF
/// chunks, e.g. after a crash while chunks were being deleted. The chunks
/// are encoded to a side file and neither file is ever overwritten or
/// deleted: the longer one becomes the archive, the other stays next to it.
enum MeetingArchiveMerge {
    /// `<stem>.<label>.m4a`, then `<stem>.<label> 1.m4a` … until free.
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
        let previous = uniqueSibling(of: archive, label: "previous")
        try fm.moveItem(at: archive, to: previous)
        do {
            try fm.moveItem(at: encoded, to: archive)
        } catch {
            try? fm.moveItem(at: previous, to: archive)
            throw error
        }
    }
}
