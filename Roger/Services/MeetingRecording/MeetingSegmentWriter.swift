import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingSegmentWriter")

/// Writes one chronological transcript segment ("<yyyy-MM-dd HH-mm-ss>.md")
/// into the session folder: the audio between two screenshot checkpoints.
/// Segment files sort between the screenshots around them, so the folder
/// reads as an alternating md/png timeline. Live checkpoint writes carry
/// `status: draft`; finalisation rewrites every segment from the full-audio
/// pass under the same names with `status: stable`.
///
/// Only drafts are replaced or deleted. Any other segment (stable from an
/// earlier finalisation and maybe edited, or without readable frontmatter)
/// is first moved aside to `<name>.previous.md` (`<name>.previous 1.md` …),
/// so a retry never loses edits.
enum MeetingSegmentWriter {
    /// Returns nil without writing when `paragraphs` is empty: a screenshot
    /// with no speech before it needs no transcript file. `chunkEnd` is the
    /// capture time of the screenshot that closes the segment, or the end of
    /// the recording for the last one. Throws without writing when an
    /// existing non-draft segment cannot be moved aside.
    @discardableResult
    static func write(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        sessionStartedAt: Date,
        chunkStart: Date,
        chunkEnd: Date,
        folder: URL,
        provisional: Bool
    ) throws -> URL? {
        guard !paragraphs.isEmpty else { return nil }
        let meetingTitle = "Meeting \(MeetingTranscriptWriter.displayDate(sessionStartedAt))"
        var fm = TranscriptFrontmatter(
            title: "\(meetingTitle), from \(timeOfDay(chunkStart))",
            description: "Part of a meeting transcript: what was said between two slide screenshots.",
            tags: ["meeting", "segment"],
            sourceDate: chunkStart,
            temporalConfidence: .explicit,
            status: provisional ? "draft" : "stable"
        )
        fm.add("started_at", date: chunkStart)
        fm.add("ended_at", date: max(chunkStart, chunkEnd))
        fm.add("meeting", "transcript.md")
        var out = fm.render()
        for paragraph in paragraphs {
            out += MeetingTranscriptWriter.paragraphMarkdown(paragraph, sessionStart: sessionStartedAt)
        }
        let url = folder.appendingPathComponent(fileName(chunkStart: chunkStart))
        try setAsideUnlessDraft(url)
        try out.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Wrote segment \(url.lastPathComponent, privacy: .public) (\(paragraphs.count) paragraphs\(provisional ? ", provisional" : ""))")
        return url
    }

    /// True when the file is a live draft (`status: draft`) that finalisation may replace.
    static func isDraft(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return LibraryFrontmatterParser.parse(text)?.scalars["status"] == "draft"
    }

    /// Moves an existing segment that is not a draft aside. Throws when that
    /// fails, so the caller does not write over it.
    static func setAsideUnlessDraft(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), !isDraft(url) else { return }
        let aside = try MeetingArchiveMerge.moveAside(url)
        logger.notice("Kept \(url.lastPathComponent, privacy: .public) as \(aside.lastPathComponent, privacy: .public)")
    }

    private static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func fileName(chunkStart: Date) -> String {
        MeetingCheckpointStore.stem(for: chunkStart) + ".md"
    }

    /// Finalisation cleanup for a segment whose range turned out empty: a
    /// draft is deleted, anything else is moved aside.
    static func removeIfExists(chunkStart: Date, folder: URL) {
        let url = folder.appendingPathComponent(fileName(chunkStart: chunkStart))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if isDraft(url) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try setAsideUnlessDraft(url)
        } catch {
            logger.warning("Could not move \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}
