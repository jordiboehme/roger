import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingSegmentWriter")

/// Writes one chronological transcript segment ("<yyyy-MM-dd HH-mm-ss>.md")
/// into the session folder — the audio between two screenshot checkpoints.
/// Segment files sort lexicographically between the screenshots around them,
/// so the folder reads as an alternating md/png timeline. Live checkpoint
/// writes are marked `provisional: true`; finalisation rewrites every segment
/// from the authoritative full-audio pass under the same deterministic names.
enum MeetingSegmentWriter {
    /// Returns nil without writing when `paragraphs` is empty — a screenshot
    /// with no speech before it needs no transcript file.
    @discardableResult
    static func write(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        sessionStartedAt: Date,
        chunkStart: Date,
        folder: URL,
        provisional: Bool
    ) throws -> URL? {
        guard !paragraphs.isEmpty else { return nil }
        var out = "---\n"
        out += "type: meeting-segment\n"
        out += "segmentStart: \(MeetingTranscriptWriter.isoDate(chunkStart))\n"
        if provisional {
            out += "provisional: true\n"
        }
        out += "---\n\n"
        for paragraph in paragraphs {
            out += MeetingTranscriptWriter.paragraphMarkdown(paragraph, sessionStart: sessionStartedAt)
        }
        let url = folder.appendingPathComponent(fileName(chunkStart: chunkStart))
        try out.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Wrote segment \(url.lastPathComponent, privacy: .public) (\(paragraphs.count) paragraphs\(provisional ? ", provisional" : ""))")
        return url
    }

    static func fileName(chunkStart: Date) -> String {
        MeetingCheckpointStore.stem(for: chunkStart) + ".md"
    }

    /// Finalisation cleanup: drops a stale provisional segment whose
    /// authoritative paragraph range turned out empty.
    static func removeIfExists(chunkStart: Date, folder: URL) {
        let url = folder.appendingPathComponent(fileName(chunkStart: chunkStart))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
