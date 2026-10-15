import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LogEntryWriter")

/// One spoken log entry, ready to be written.
struct LogEntry: Sendable {
    let text: String
    let startedAt: Date
    let endedAt: Date
    let presetName: String
    /// ISO code when known (preset pin or detected), else nil.
    let language: String?
    /// Speaker paragraphs when the log recorded system audio, else nil.
    let paragraphs: [MeetingTranscriptMerger.Paragraph]?

    init(
        text: String, startedAt: Date, endedAt: Date, presetName: String, language: String?,
        paragraphs: [MeetingTranscriptMerger.Paragraph]? = nil
    ) {
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.presetName = presetName
        self.language = language
        self.paragraphs = paragraphs
    }
}

/// Writes log entries as OKF Markdown files into
/// `<library>/Logs/YYYY/MM/<yyyy-MM-dd HH-mm-ss>.md`, optionally with the
/// recording as `.m4a` next to it. File names never change after writing,
/// so paths handed to agents stay valid.
enum LogEntryWriter {
    /// Number of words from the text that go into the title.
    static let titleWordCount = 6

    static func baseName(for date: Date) -> String {
        formatter("yyyy-MM-dd HH-mm-ss").string(from: date)
    }

    static func title(for entry: LogEntry) -> String {
        title(for: entry, time: displayTime(entry.startedAt))
    }

    /// `time` is the `yyyy-MM-dd HH:mm` display string of `entry.startedAt`.
    private static func title(for entry: LogEntry, time: String) -> String {
        let heading = "Log \(time)"
        // A speaker log titles itself from its first paragraph only.
        let source = entry.paragraphs?.first?.text ?? entry.text
        let words = source.split(whereSeparator: \.isWhitespace).prefix(titleWordCount)
        var snippet = words.joined(separator: " ")
        while let last = snippet.last, ",.;:!?".contains(last) {
            snippet.removeLast()
        }
        return snippet.isEmpty ? heading : "\(heading) - \(snippet)"
    }

    static func content(for entry: LogEntry, audioFileName: String?, generatedAt: Date) -> String {
        let day = formatter("yyyy-MM-dd").string(from: entry.startedAt)
        let clock = formatter("HH:mm").string(from: entry.startedAt)
        let time = "\(day) \(clock)"
        var sources: [TranscriptFrontmatter.Source] = []
        if let audioFileName {
            sources.append(.init(id: "audio", resource: audioFileName))
        }
        var fm = TranscriptFrontmatter(
            title: title(for: entry, time: time),
            description: "Log entry recorded with Roger on \(day) at \(clock).",
            tags: ["log"],
            generatedAt: generatedAt,
            sourceDate: entry.startedAt,
            temporalConfidence: .explicit,
            sources: sources,
            status: "stable"
        )
        fm.add("started_at", date: entry.startedAt)
        fm.add("ended_at", date: entry.endedAt)
        fm.add("duration_seconds", Int(entry.endedAt.timeIntervalSince(entry.startedAt).rounded()))
        fm.add("preset", entry.presetName)
        if let language = entry.language {
            fm.add("language", language)
        }
        if let paragraphs = entry.paragraphs {
            fm.add("speaker_count", Set(paragraphs.map(\.speaker)).count)
        }
        let body: String
        if let paragraphs = entry.paragraphs {
            body = paragraphs.map { MeetingTranscriptWriter.paragraphMarkdown($0, sessionStart: entry.startedAt) }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fm.render() + "# Log \(time)\n\n\(body)\n"
    }

    /// `base`, `base 1`, `base 2` … until neither `.md` nor `.m4a` exists.
    static func uniqueBaseName(_ base: String, in folder: URL) -> String {
        let fm = FileManager.default
        func taken(_ name: String) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent("\(name).md").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("\(name).m4a").path)
        }
        var candidate = base
        var suffix = 1
        while taken(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Writes the entry and returns the `.md` URL. Audio is encoded first,
    /// off the main actor; if that fails the entry is still written, without
    /// `sources`, and any partial `.m4a` is removed.
    static func write(
        _ entry: LogEntry,
        layout: LibraryLayout,
        audioSamples: [Float]?,
        defaultRoot: URL = LibraryLayout.defaultRoot,
        encodeAudio: @escaping @Sendable ([Float], URL) throws -> Void = LogAudioEncoder.writeM4A
    ) async throws -> URL {
        try LibraryLayout.prepareRootForWriting(layout, defaultRoot: defaultRoot)
        let folder = layout.monthFolder(.logs, for: entry.startedAt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = uniqueBaseName(baseName(for: entry.startedAt), in: folder)
        let markdownURL = folder.appendingPathComponent("\(name).md")

        var audioFileName: String?
        if let samples = audioSamples, !samples.isEmpty {
            let audioURL = folder.appendingPathComponent("\(name).m4a")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try encodeAudio(samples, audioURL)
                }.value
                audioFileName = audioURL.lastPathComponent
            } catch {
                logger.error("Log audio encode failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let markdown = content(for: entry, audioFileName: audioFileName, generatedAt: .now)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        return markdownURL
    }

    // MARK: - Helpers

    /// `yyyy-MM-dd HH:mm` in local time.
    private static func displayTime(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }
}
