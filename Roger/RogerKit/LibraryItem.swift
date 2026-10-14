import Foundation

/// What a library entry is. Decided by the tags Roger writes (see
/// `LibraryItemReader`).
public enum LibraryItemKind: String, CaseIterable, Sendable, Hashable, Codable {
    case log
    case meeting
    case transcript

    public var displayName: String {
        switch self {
        case .log: return "Log"
        case .meeting: return "Meeting"
        case .transcript: return "Transcript"
        }
    }

    public var pluralName: String {
        switch self {
        case .log: return "Logs"
        case .meeting: return "Meetings"
        case .transcript: return "Transcripts"
        }
    }

    public var systemImage: String {
        switch self {
        case .log: return "book.closed"
        case .meeting: return "person.2"
        case .transcript: return "doc.text"
        }
    }
}

/// One entry in the library window: a log entry, a meeting or a file
/// transcript, read from its Markdown file.
public struct LibraryItem: Identifiable, Hashable, Sendable {
    /// The Markdown file (meetings: `transcript.md`). For an unfinished
    /// meeting without a transcript, the session folder.
    public var url: URL
    /// Meetings: the session folder. Logs and transcripts: the folder that
    /// holds the file.
    public var folderURL: URL
    public var kind: LibraryItemKind
    public var title: String
    /// Recording start (`started_at`), else `source_date`, else file dates.
    public var date: Date
    public var durationSeconds: Int?
    public var language: String?
    public var preset: String?
    public var speakerCount: Int?
    public var screenshotCount: Int
    /// Existing files from `sources` with id `audio`, `mic`, `system` or `media`.
    public var audioFiles: [URL]
    public var firstLine: String
    /// Lowercased title and body, for search.
    public var searchText: String
    /// The session still has audio to transcribe (see `MeetingSessionScanner.isUnfinished`).
    public var isUnfinished: Bool

    public var id: String { url.path }
    public var hasAudio: Bool { !audioFiles.isEmpty }
    public var hasMarkdown: Bool { url.pathExtension.lowercased() == "md" }

    public init(
        url: URL,
        folderURL: URL,
        kind: LibraryItemKind,
        title: String,
        date: Date,
        durationSeconds: Int?,
        language: String?,
        preset: String?,
        speakerCount: Int?,
        screenshotCount: Int,
        audioFiles: [URL],
        firstLine: String,
        searchText: String,
        isUnfinished: Bool
    ) {
        self.url = url
        self.folderURL = folderURL
        self.kind = kind
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.language = language
        self.preset = preset
        self.speakerCount = speakerCount
        self.screenshotCount = screenshotCount
        self.audioFiles = audioFiles
        self.firstLine = firstLine
        self.searchText = searchText
        self.isUnfinished = isUnfinished
    }
}
