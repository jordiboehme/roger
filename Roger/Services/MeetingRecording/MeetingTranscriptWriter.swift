import Foundation

/// Writes a meeting transcript as a single Markdown file inside the session
/// folder. Format is designed for ingestion by note-keeping systems like
/// basic-memory: YAML frontmatter with stable keys, body of timestamped
/// speaker paragraphs.
///
/// Each paragraph header is `**Speaker** [offset · localDateTime]`, where
/// `offset` is HH:MM:SS from recording start and `localDateTime` is the
/// absolute wall-clock time in the machine's local timezone. The absolute
/// time lets an ingesting agent correlate the transcript with externally
/// captured artifacts — e.g. screenshots whose filenames embed a local
/// timestamp — by matching the artifact's time against paragraph start times.
enum MeetingTranscriptWriter {
    struct Metadata {
        let session: MeetingSession
        let durationSeconds: Int
        let speakerCount: Int
        let language: String?
        let micPresent: Bool
        let systemPresent: Bool
        let diarizationFailed: Bool
        let appVersion: String
        let modelDescription: String
    }

    static func write(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        metadata: Metadata
    ) throws -> URL {
        let url = metadata.session.transcriptURL
        let content = buildContent(paragraphs: paragraphs, metadata: metadata)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func buildContent(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        metadata: Metadata
    ) -> String {
        var out = ""
        out += "---\n"
        out += "title: \"Meeting \(displayDate(metadata.session))\"\n"
        out += "type: meeting-recording\n"
        out += "date: \(isoDate(metadata.session.startedAt))\n"
        out += "durationSeconds: \(metadata.durationSeconds)\n"
        if metadata.micPresent {
            out += "mic: ./\(metadata.session.micArchiveURL.lastPathComponent)\n"
        }
        if metadata.systemPresent {
            out += "systemAudio: ./\(metadata.session.systemArchiveURL.lastPathComponent)\n"
        }
        out += "speakerCount: \(metadata.speakerCount)\n"
        if let lang = metadata.language {
            out += "language: \(lang)\n"
        }
        if metadata.diarizationFailed {
            out += "diarizationFailed: true\n"
        }
        out += "roger:\n"
        out += "  version: \(metadata.appVersion)\n"
        out += "  model: \"\(metadata.modelDescription)\"\n"
        out += "---\n\n"
        out += "# Meeting \(displayDate(metadata.session))\n\n"

        for paragraph in paragraphs {
            let rel = formatTimestamp(paragraph.startTime)
            let abs = absoluteTimestamp(start: metadata.session.startedAt, offset: paragraph.startTime)
            out += "**\(paragraph.speaker)** [\(rel) · \(abs)]\n"
            out += paragraph.text
            out += "\n\n"
        }
        return out
    }

    private static func displayDate(_ session: MeetingSession) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: session.startedAt)
    }

    private static func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Absolute wall-clock time in the local timezone, so transcript times line
    /// up with screenshot filenames (which macOS writes in local time).
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"   // timeZone defaults to .current (local)
        return f
    }()

    private static func absoluteTimestamp(start: Date, offset: Float) -> String {
        // Round to whole seconds so the absolute time stays in lockstep with the
        // relative HH:MM:SS produced by formatTimestamp.
        absoluteFormatter.string(from: start.addingTimeInterval(TimeInterval(offset.rounded())))
    }

    private static func formatTimestamp(_ seconds: Float) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
