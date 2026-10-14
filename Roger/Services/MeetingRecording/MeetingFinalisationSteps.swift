import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingFinalisation")

/// The file steps of a meeting finalisation after transcription: segment
/// files, `transcript.md`, the change record, the archive cleanup and the
/// error the menu bar shows. `MeetingRecordingService` keeps capture,
/// encoding, transcription and the UI state.
@MainActor
enum MeetingFinalisationSteps {
    /// What happened to one track's audio before transcription.
    struct Track: Equatable, Sendable {
        /// Chunks were kept for a retry (the encode failed or some chunks
        /// could not be read).
        var needsRetry = false
        /// The new encode stayed beside the archive (`mic.leftover.m4a`).
        var leftover: URL?
        /// The archive existed before this run; it may be the only copy.
        var archiveExisted = false

        /// The transcript does not cover all of this track's audio.
        var audioFailed: Bool { needsRetry || leftover != nil }
    }

    struct Input {
        let session: MeetingSession
        let paragraphs: [MeetingTranscriptMerger.Paragraph]
        let metadata: MeetingTranscriptWriter.Metadata
        let markers: [MeetingCheckpointMarker]
        /// `markers.json`'s start time, else the session's.
        let segmentStart: Date
        let durationSeconds: Int
        let mic: Track
        let system: Track
        let sleepInterrupted: Bool
    }

    enum Outcome {
        /// `transcript.md` is on disk. `error` is what the menu bar shows
        /// (nil: nothing).
        case finished(transcript: URL, error: MeetingRecordingError?)
        /// `transcript.md` could not be written. Nothing was recorded and
        /// no audio was deleted, so a retry can run.
        case failed(String)
    }

    /// All audio stays when the setting says so, when an archive existed
    /// before this run (it may be the only copy) or when a track failed (a
    /// retry needs the other track's archive). The transcript then lists
    /// exactly the files that stay on disk.
    static func keepsAudio(setting: Bool, mic: Track, system: Track) -> Bool {
        setting || mic.archiveExisted || system.archiveExisted || mic.audioFailed || system.audioFailed
    }

    /// `recordWritten` runs once, right after `transcript.md` is on disk.
    static func run(_ input: Input, recordWritten: (URL) -> Void) -> Outcome {
        if !input.markers.isEmpty {
            writeSegments(input)
        }
        let transcriptURL: URL
        do {
            transcriptURL = try MeetingTranscriptWriter.write(paragraphs: input.paragraphs, metadata: input.metadata, markers: input.markers)
        } catch {
            return .failed(error.localizedDescription)
        }
        recordWritten(transcriptURL)

        if !input.metadata.audioKept, !input.paragraphs.isEmpty {
            // Only after the transcript exists: the CAF chunks are already
            // gone, so these archives were the last copy of the audio.
            try? FileManager.default.removeItem(at: input.session.micArchiveURL)
            try? FileManager.default.removeItem(at: input.session.systemArchiveURL)
        }

        // Kept chunks: the session shows up again for a retry. A leftover
        // file only: the audio is safe there, nothing to retry.
        let error = MeetingRecordingError.afterFinalisation(
            micNeedsRetry: input.mic.needsRetry,
            systemNeedsRetry: input.system.needsRetry,
            setAside: [input.mic.leftover, input.system.leftover].compactMap { $0?.lastPathComponent }
        ) ?? (input.sleepInterrupted ? .sleepInterrupted : nil)
        return .finished(transcript: transcriptURL, error: error)
    }

    /// Rewrites every segment from the full pass (drafts are replaced, a
    /// stable segment is moved aside first). A segment whose range has no
    /// speech is removed when it is a draft, else moved aside.
    private static func writeSegments(_ input: Input) {
        let folder = input.session.folder
        for chunk in MeetingCheckpointStore.chunks(sessionStartedAt: input.segmentStart, markers: input.markers) {
            let paragraphs = input.paragraphs.filter { chunk.range.contains(Double($0.startTime)) }
            guard !paragraphs.isEmpty else {
                MeetingSegmentWriter.removeIfExists(chunkStart: chunk.start, folder: folder)
                continue
            }
            do {
                try MeetingSegmentWriter.write(
                    paragraphs: paragraphs,
                    sessionStartedAt: input.segmentStart,
                    chunkStart: chunk.start,
                    chunkEnd: input.segmentStart.addingTimeInterval(
                        chunk.range.upperBound.isFinite ? chunk.range.upperBound : Double(input.durationSeconds)
                    ),
                    folder: folder,
                    provisional: false
                )
            } catch {
                logger.warning("Segment write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
