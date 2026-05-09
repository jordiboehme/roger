import Foundation

/// Persistent record of a single meeting recording session. The directory at
/// `folder` contains:
/// - `mic-001.caf` … `mic-NNN.caf` (and `mic.m4a` after finalisation)
/// - `system-001.caf` … `system-NNN.caf` (and `system.m4a` after finalisation)
/// - `transcript.md` (after transcription)
struct MeetingSession: Sendable, Equatable, Identifiable {
    let id: UUID
    let folder: URL
    let startedAt: Date

    /// Default name format: `YYYY-MM-DD HH-mm`. Single source of truth so
    /// recovery and the Recordings tab agree on what to look for.
    static let folderNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    /// Builds a fresh session under `parent`, creating its folder.
    static func create(in parent: URL, startedAt: Date = .now) throws -> MeetingSession {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let baseName = folderNameFormatter.string(from: startedAt)
        let folderURL = uniqueFolder(parent: parent, base: baseName)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        return MeetingSession(id: UUID(), folder: folderURL, startedAt: startedAt)
    }

    /// Walks `<base>`, `<base> 1`, `<base> 2` … until a name doesn't exist.
    private static func uniqueFolder(parent: URL, base: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    var micArchiveURL: URL { folder.appendingPathComponent("mic.m4a") }
    var systemArchiveURL: URL { folder.appendingPathComponent("system.m4a") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
}
