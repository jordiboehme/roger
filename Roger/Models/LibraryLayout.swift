import Foundation

/// Folder layout of Roger's library: one root with `Logs/`, `Meetings/` and
/// `Transcripts/`, each split into `YYYY/MM/` by the local recording time.
/// The single place that knows where Roger's files go.
struct LibraryLayout: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case logs = "Logs"
        case meetings = "Meetings"
        case transcripts = "Transcripts"
    }

    let root: URL

    /// `~/Documents/Roger/`.
    static var defaultRoot: URL {
        documents.appendingPathComponent("Roger", isDirectory: true)
    }

    /// Where meetings went before the library existed: `~/Documents/Roger Recordings/`.
    static var legacyRecordingsFolder: URL {
        documents.appendingPathComponent("Roger Recordings", isDirectory: true)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    func kindFolder(_ kind: Kind) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// `<root>/<Kind>/YYYY/MM/` for the local month of `date`.
    func monthFolder(_ kind: Kind, for date: Date, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        return kindFolder(kind)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
    }
}
