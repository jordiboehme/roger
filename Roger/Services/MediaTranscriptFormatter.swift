import Foundation

/// Builds the Markdown transcript of a dropped audio or video file: OKF
/// frontmatter (see `TranscriptFrontmatter`) with the recording time, a title
/// and either timestamped speaker paragraphs or one block of plain text.
enum MediaTranscriptFormatter {
    static func content(
        source: URL,
        destination: URL,
        recording: MediaAudioExtractor.RecordingInfo,
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        plainText: String,
        language: String?,
        diarized: Bool,
        diarizationFailed: Bool
    ) -> String {
        let title = source.deletingPathExtension().lastPathComponent
        let resource = relativePath(from: destination.deletingLastPathComponent(), to: source)
        let speakerCount = Set(paragraphs.map(\.speaker)).count
        let duration = Int(recording.durationSeconds.rounded())

        var fm = TranscriptFrontmatter(
            title: title,
            description: description(
                isVideo: MediaAudioExtractor.isVideo(source),
                durationSeconds: duration,
                speakerCount: diarized ? speakerCount : nil,
                confidence: recording.confidence
            ),
            resource: resource,
            tags: ["transcript"],
            sourceDate: recording.startedAt,
            temporalConfidence: recording.confidence,
            sources: [.init(id: "media", resource: resource, lastModified: recording.fileModifiedAt)],
            status: "stable"
        )
        fm.add("started_at", date: recording.startedAt)
        if duration > 0 {
            fm.add("ended_at", date: recording.startedAt.addingTimeInterval(TimeInterval(duration)))
            fm.add("duration_seconds", duration)
        }
        if diarized {
            fm.add("speaker_count", speakerCount)
        }
        if let language {
            fm.add("language", language)
        }
        if diarized {
            fm.add("diarization_model", TranscriptFrontmatter.diarizationModel)
        }
        if diarizationFailed {
            fm.add("diarization_failed", true)
        }

        var out = fm.render()
        out += "# \(title)\n\n"
        if paragraphs.isEmpty {
            out += plainText + "\n"
        } else {
            // Wall-clock times only when the recording date is known; an
            // approximated date would make them look more exact than they are.
            let start = recording.confidence == .explicit ? recording.startedAt : nil
            for paragraph in paragraphs {
                out += MeetingTranscriptWriter.paragraphMarkdown(paragraph, sessionStart: start)
            }
        }
        return out
    }

    private static func description(
        isVideo: Bool,
        durationSeconds: Int,
        speakerCount: Int?,
        confidence: TranscriptFrontmatter.TemporalConfidence
    ) -> String {
        var text = "Transcript of \(isVideo ? "a video" : "an audio") recording"
        if durationSeconds >= 60 {
            let minutes = Int((Double(durationSeconds) / 60).rounded())
            text += ", \(minutes) minute\(minutes == 1 ? "" : "s")"
        } else if durationSeconds > 0 {
            text += ", \(durationSeconds) second\(durationSeconds == 1 ? "" : "s")"
        }
        if let speakerCount {
            text += ", \(speakerCount) speaker\(speakerCount == 1 ? "" : "s")"
        }
        text += ", transcribed on this Mac by Roger."
        if confidence == .inferred {
            text += " The recording date is taken from the file's creation date."
        }
        return text
    }

    /// Path of `target` relative to the folder `base`, with `..` steps as
    /// needed. Falls back to the absolute path when the two share no folder.
    static func relativePath(from base: URL, to target: URL) -> String {
        let baseParts = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let targetParts = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(baseParts.count, targetParts.count), baseParts[common] == targetParts[common] {
            common += 1
        }
        guard common > 1 else { return target.path }
        let ups = Array(repeating: "..", count: baseParts.count - common)
        return (ups + targetParts[common...]).joined(separator: "/")
    }
}
