import Foundation

/// Writes a meeting transcript as a single Markdown file inside the session
/// folder: an OKF concept with Crystalline-compatible frontmatter (see
/// `TranscriptFrontmatter`) and a body of timestamped speaker paragraphs.
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
        /// True when at least one track went through speaker diarization.
        let diarized: Bool
        let diarizationFailed: Bool
    }

    /// `markers` are screenshot checkpoints to weave into the body as inline
    /// image references at their chronological position between paragraphs.
    static func write(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        metadata: Metadata,
        markers: [MeetingCheckpointMarker] = []
    ) throws -> URL {
        let url = metadata.session.transcriptURL
        let content = buildContent(paragraphs: paragraphs, metadata: metadata, markers: markers)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func buildContent(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        metadata: Metadata,
        markers: [MeetingCheckpointMarker]
    ) -> String {
        let session = metadata.session
        let endedAt = session.startedAt.addingTimeInterval(TimeInterval(metadata.durationSeconds))
        var sources: [TranscriptFrontmatter.Source] = []
        if metadata.micPresent {
            sources.append(.init(id: "mic", resource: session.micArchiveURL.lastPathComponent))
        }
        if metadata.systemPresent {
            sources.append(.init(id: "system", resource: session.systemArchiveURL.lastPathComponent))
        }
        var fm = TranscriptFrontmatter(
            title: "Meeting \(displayDate(session))",
            description: description(metadata, screenshots: markers.count),
            tags: ["meeting", "transcript"],
            sourceDate: session.startedAt,
            temporalConfidence: .explicit,
            sources: sources,
            status: "stable"
        )
        fm.add("started_at", date: session.startedAt)
        fm.add("ended_at", date: endedAt)
        fm.add("duration_seconds", metadata.durationSeconds)
        fm.add("speaker_count", metadata.speakerCount)
        if !markers.isEmpty {
            fm.add("screenshot_count", markers.count)
        }
        if let lang = metadata.language {
            fm.add("language", lang)
        }
        if metadata.diarized && !metadata.diarizationFailed {
            fm.add("diarization_model", TranscriptFrontmatter.diarizationModel)
        }
        if metadata.diarizationFailed {
            fm.add("diarization_failed", true)
        }

        var out = fm.render()
        out += "# Meeting \(displayDate(metadata.session))\n\n"

        var pendingMarkers = markers.sorted { $0.offsetSeconds < $1.offsetSeconds }
        for paragraph in paragraphs {
            while let next = pendingMarkers.first, Double(paragraph.startTime) >= next.offsetSeconds {
                out += imageReference(next)
                pendingMarkers.removeFirst()
            }
            out += paragraphMarkdown(paragraph, sessionStart: metadata.session.startedAt)
        }
        for marker in pendingMarkers {
            out += imageReference(marker)
        }
        return out
    }

    /// One plain sentence saying what the file is, for OKF indexes and search
    /// snippets. Not a summary of what was said.
    private static func description(_ metadata: Metadata, screenshots: Int) -> String {
        let minutes = max(1, Int((Double(metadata.durationSeconds) / 60).rounded()))
        var text = "Meeting transcript, \(minutes) minute\(minutes == 1 ? "" : "s"), "
        text += "\(metadata.speakerCount) speaker\(metadata.speakerCount == 1 ? "" : "s")"
        if screenshots > 0 {
            text += ", \(screenshots) slide screenshot\(screenshots == 1 ? "" : "s")"
        }
        return text + ", recorded and transcribed on this Mac by Roger."
    }

    private static func imageReference(_ marker: MeetingCheckpointMarker) -> String {
        "![](\(marker.imageFile))\n\n"
    }

    /// One paragraph block: `**Speaker** [HH:MM:SS · yyyy-MM-dd HH:mm:ss]`
    /// header plus text. Shared with `MeetingSegmentWriter` and dropped-file
    /// transcripts so every Roger transcript uses the same body format.
    /// Without a known start time the header carries the offset only.
    static func paragraphMarkdown(_ paragraph: MeetingTranscriptMerger.Paragraph, sessionStart: Date?) -> String {
        let rel = formatTimestamp(paragraph.startTime)
        guard let sessionStart else {
            return "**\(paragraph.speaker)** [\(rel)]\n\(paragraph.text)\n\n"
        }
        let abs = absoluteTimestamp(start: sessionStart, offset: paragraph.startTime)
        return "**\(paragraph.speaker)** [\(rel) · \(abs)]\n\(paragraph.text)\n\n"
    }

    private static func displayDate(_ session: MeetingSession) -> String {
        displayDate(session.startedAt)
    }

    /// `yyyy-MM-dd HH:mm` in local time, used in meeting and segment titles.
    static func displayDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
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
