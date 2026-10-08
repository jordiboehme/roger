import FluidAudio
import Foundation

/// YAML frontmatter for every Markdown transcript Roger writes (meeting
/// transcript, meeting segments, dropped media files). Each file is an
/// Open Knowledge Format (OKF v0.2) concept that Crystalline can index as an
/// engram without changes:
///
/// - OKF keys first, in a fixed order, then Roger's own snake_case keys.
/// - `generated` names Roger and the speech model that produced the text.
/// - Crystalline's typed dates (`recorded_at`, `source_date`) are plain
///   `YYYY-MM-DD`; exact instants go in Roger's `started_at` / `ended_at`.
/// - Values that come from outside (file names, languages, model names) are
///   double-quoted and escaped so titles with `:` or `#` stay valid YAML.
struct TranscriptFrontmatter {
    /// How sure Roger is about the recording time. Crystalline's
    /// `temporal_confidence` vocabulary.
    enum TemporalConfidence: String {
        /// Roger recorded it, or the media file carries a recording date.
        case explicit
        /// Approximated from the file's creation date.
        case inferred
    }

    /// One `sources` entry (OKF §5.1). `resource` is a path relative to the
    /// Markdown file.
    struct Source {
        let id: String
        let resource: String
        var lastModified: Date?
    }

    private var lines: [String] = []

    /// Starts with the OKF core block shared by all transcript kinds.
    init(
        title: String,
        description: String,
        resource: String? = nil,
        tags: [String],
        generatedAt: Date = .now,
        sourceDate: Date,
        temporalConfidence: TemporalConfidence,
        sources: [Source] = [],
        status: String
    ) {
        lines.append("type: source")
        lines.append("title: \(Self.quoted(title))")
        lines.append("description: \(Self.quoted(description))")
        if let resource {
            lines.append("resource: \(Self.quoted(resource))")
        }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("generated: { by: roger/\(Self.appVersion), model: \(Self.quoted(Self.speechModel)), at: \(Self.timestamp(generatedAt)) }")
        lines.append("recorded_at: \(Self.day(generatedAt))")
        lines.append("source_date: \(Self.day(sourceDate))")
        lines.append("temporal_confidence: \(temporalConfidence.rawValue)")
        if !sources.isEmpty {
            lines.append("sources:")
            for source in sources {
                var entry = "id: \(source.id), resource: \(Self.quoted(source.resource))"
                if let modified = source.lastModified {
                    entry += ", last_modified: \(Self.timestamp(modified))"
                }
                lines.append("  - { \(entry) }")
            }
        }
        lines.append("status: \(status)")
    }

    // MARK: - Roger's own keys

    mutating func add(_ key: String, date: Date) {
        lines.append("\(key): \(Self.timestamp(date))")
    }

    mutating func add(_ key: String, _ value: Int) {
        lines.append("\(key): \(value)")
    }

    mutating func add(_ key: String, _ value: Bool) {
        lines.append("\(key): \(value)")
    }

    mutating func add(_ key: String, _ value: String) {
        lines.append("\(key): \(Self.quoted(value))")
    }

    func render() -> String {
        "---\n" + lines.joined(separator: "\n") + "\n---\n\n"
    }

    // MARK: - Shared values

    /// Hugging Face repo of the speech model, FluidAudio's stable name for it.
    /// Keep in step with `TranscriptionEngine.modelVersion`.
    static let speechModel = Repo.parakeetUltra.rawValue

    /// Hugging Face repo of the speaker diarization models.
    static let diarizationModel = Repo.diarizer.rawValue

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// RFC 3339 with the local UTC offset and whole seconds.
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Local calendar day as `YYYY-MM-DD`, the only form Crystalline's typed
    /// date fields accept.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Double-quoted YAML scalar. Escapes `"` and `\`, common control
    /// characters as `\n` style and the rest (plus U+2028/U+2029, which YAML
    /// readers take as line breaks) as `\uXXXX`.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F
                    || scalar.value == 0x2028 || scalar.value == 0x2029
                    || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
