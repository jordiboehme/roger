import Foundation

/// Writes a dropped file's Markdown transcript next to the source or into
/// the user's configured folder, with automatic collision handling.
enum TranscriptOutputWriter {
    enum WriteError: LocalizedError {
        case destinationNotWritable(URL)

        var errorDescription: String? {
            switch self {
            case .destinationNotWritable(let url):
                return "Can't write the transcript to \(url.path)."
            }
        }
    }

    /// Writes a `.md` file derived from `source`. The file name is
    /// `<sourceLastPathComponent>.md` (e.g. `meeting.m4a.md`). If that file
    /// already exists, appends `-1`, `-2` … until a free name is found.
    /// `content` receives the final destination so it can point back at the
    /// source with a relative path. Returns the URL of the written file.
    static func write(
        source: URL,
        location: FileTranscriptOutputLocation,
        customFolder: URL?,
        content: (URL) -> String
    ) throws -> URL {
        let baseDir: URL
        switch location {
        case .alongsideSource:
            baseDir = source.deletingLastPathComponent()
        case .customFolder:
            baseDir = customFolder ?? source.deletingLastPathComponent()
        }

        let candidate = baseDir.appendingPathComponent("\(source.lastPathComponent).md")
        let destination = uniqueDestination(for: candidate)

        do {
            try content(destination).write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.destinationNotWritable(destination)
        }
        return destination
    }

    /// Walks `base`, `base-1`, `base-2` … until a file doesn't exist.
    /// Handles multi-dot filenames (`meeting.m4a.md`) by inserting the
    /// suffix before the final extension only.
    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let dir = url.deletingLastPathComponent()
        let full = url.lastPathComponent
        // Split into stem + final extension so we append `-N` to the stem.
        let ext = (full as NSString).pathExtension
        let stem = (full as NSString).deletingPathExtension

        for i in 1..<1000 {
            let candidateName = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Extreme fallback — if 1000 collisions happen, overwrite the base.
        return url
    }
}
