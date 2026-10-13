import Foundation

/// What a library entry is. Decided by the tags Roger writes (see
/// `LibraryItemReader`).
enum LibraryItemKind: String, CaseIterable, Sendable, Hashable {
    case log
    case meeting
    case transcript

    var displayName: String {
        switch self {
        case .log: return "Log"
        case .meeting: return "Meeting"
        case .transcript: return "Transcript"
        }
    }

    var pluralName: String {
        switch self {
        case .log: return "Logs"
        case .meeting: return "Meetings"
        case .transcript: return "Transcripts"
        }
    }

    var systemImage: String {
        switch self {
        case .log: return "book.closed"
        case .meeting: return "person.2"
        case .transcript: return "doc.text"
        }
    }
}

/// One entry in the library window: a log entry, a meeting or a file
/// transcript, read from its Markdown file.
struct LibraryItem: Identifiable, Hashable, Sendable {
    /// The Markdown file (meetings: `transcript.md`). For an unfinished
    /// meeting without a transcript, the session folder.
    var url: URL
    /// Meetings: the session folder. Logs and transcripts: the folder that
    /// holds the file.
    var folderURL: URL
    var kind: LibraryItemKind
    var title: String
    /// Recording start (`started_at`), else `source_date`, else file dates.
    var date: Date
    var durationSeconds: Int?
    var language: String?
    var preset: String?
    var speakerCount: Int?
    var screenshotCount: Int
    /// Existing files from `sources` with id `audio`, `mic`, `system` or `media`.
    var audioFiles: [URL]
    var firstLine: String
    /// Lowercased title and body, for search.
    var searchText: String
    /// The session still has audio to transcribe (see `MeetingSessionScanner.isUnfinished`).
    var isUnfinished: Bool

    var id: String { url.path }
    var hasAudio: Bool { !audioFiles.isEmpty }
    var hasMarkdown: Bool { url.pathExtension.lowercased() == "md" }
}
