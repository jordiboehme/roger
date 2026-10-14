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
/// so a retry never loses edits. A segment whose text did not change is
/// left as it is.
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
        provisional: Bool,
        generatedAt: Date = .now
    ) throws -> URL? {
        guard !paragraphs.isEmpty else { return nil }
        let meetingTitle = "Meeting \(MeetingTranscriptWriter.displayDate(sessionStartedAt))"
        var fm = TranscriptFrontmatter(
            title: "\(meetingTitle), from \(timeOfDay(chunkStart))",
            description: "Part of a meeting transcript: what was said between two slide screenshots.",
            tags: ["meeting", "segment"],
            generatedAt: generatedAt,
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
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try? TextFile.read(url)
            if let existing, sameContent(existing, out) {
                // A retry that gives the same text: keep the file, no `.previous` copy.
                logger.info("Segment \(url.lastPathComponent, privacy: .public) is unchanged")
                return url
            }
            if !isDraft(text: existing) { try moveAside(url) }
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Wrote segment \(url.lastPathComponent, privacy: .public) (\(paragraphs.count) paragraphs\(provisional ? ", provisional" : ""))")
        return url
    }

    /// True when the file is a live draft (`status: draft`) that finalisation may replace.
    static func isDraft(_ url: URL) -> Bool {
        isDraft(text: try? TextFile.read(url))
    }

    /// True for the text of a live draft. Nil (unreadable) is not a draft.
    private static func isDraft(text: String?) -> Bool {
        guard let text else { return false }
        return LibraryFrontmatterParser.parse(text)?.scalars["status"] == "draft"
    }

    /// True when two segment texts differ at most in when Roger wrote them
    /// (the `generated` and `recorded_at` frontmatter lines).
    static func sameContent(_ a: String, _ b: String) -> Bool {
        normalised(a) == normalised(b)
    }

    private static func normalised(_ text: String) -> String {
        let parts = LibraryFrontmatterParser.split(text)
        guard let frontmatter = parts.frontmatter else { return text }
        let kept = frontmatter
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("generated:") && !$0.hasPrefix("recorded_at:") }
            .joined(separator: "\n")
        return kept + parts.body
    }

    /// Moves an existing segment aside. Throws when that fails, so the
    /// caller does not write over it.
    private static func moveAside(_ url: URL) throws {
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
        // Read once: the same text decides draft or not.
        if isDraft(text: try? TextFile.read(url)) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try moveAside(url)
        } catch {
            logger.warning("Could not move \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}
