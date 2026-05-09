import AVFoundation
import Foundation
import os

/// Concatenates a chain of CAF segment files into a single M4A archive.
///
/// Two-step recipe matching what AVFoundation expects:
/// 1. Build an `AVMutableComposition` with each segment inserted in order,
///    end-to-end. We use AVURLAsset → first audio track to ignore any
///    metadata or timing oddities the source files might carry.
/// 2. Export with `AVAssetExportSession` preset `AppleM4A` to a temp file,
///    then atomically replace the destination on success. The CAF chunks are
///    only deleted by the caller, after all per-track encodes succeed.
enum AudioSegmentConcatenator {
    private static let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AudioSegmentConcatenator")

    /// Concatenates `segments` (in order) into `destinationURL` (.m4a). Returns
    /// when the export finishes; throws on any failure.
    /// Concatenates `segments` (in order) into `destinationURL` (.m4a). Returns
    /// `true` when an output file was written, `false` when every input chunk
    /// was empty/silent (in which case no file is created — the caller should
    /// treat the track as missing). Throws on actual encode failure.
    @discardableResult
    static func concatenate(segments: [URL], destinationURL: URL) async throws -> Bool {
        guard !segments.isEmpty else {
            throw ConcatenationError.noSegments
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ConcatenationError.compositionTrackUnavailable
        }

        var insertAt = CMTime.zero
        var insertedCount = 0
        for url in segments {
            let asset = AVURLAsset(url: url)
            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                logger.warning("Segment failed to load tracks, skipping: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let sourceTrack = audioTracks.first else {
                logger.warning("Segment has no audio track, skipping: \(url.lastPathComponent, privacy: .public)")
                continue
            }
            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                logger.warning("Segment failed to load duration, skipping: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let durationSeconds = CMTimeGetSeconds(duration)
            // CAF chunks that never received any audio (e.g. a recording with
            // nothing playing on the system out) are written with a header
            // but zero frames. AVMutableComposition refuses to insert a
            // zero-length range — skip these silently.
            guard durationSeconds.isFinite, durationSeconds > 0.01 else {
                logger.info("Segment has zero duration, skipping: \(url.lastPathComponent, privacy: .public)")
                continue
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try track.insertTimeRange(range, of: sourceTrack, at: insertAt)
            } catch {
                logger.warning("Segment insertTimeRange failed, skipping: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            insertAt = CMTimeAdd(insertAt, duration)
            insertedCount += 1
            logger.debug("Concatenated \(url.lastPathComponent, privacy: .public) (\(durationSeconds)s)")
        }

        // All inputs were empty — nothing to encode. Caller treats this as
        // "no track" and the rest of the pipeline reads the missing m4a as
        // `present == false`.
        guard insertedCount > 0 else {
            logger.info("All \(segments.count) input segments were empty — skipping encode for \(destinationURL.lastPathComponent, privacy: .public)")
            return false
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConcatenationError.exportSessionUnavailable
        }
        let tempURL = destinationURL.deletingPathExtension().appendingPathExtension("tmp.m4a")
        try? FileManager.default.removeItem(at: tempURL)
        session.outputURL = tempURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        try await session.export(to: tempURL, as: .m4a)

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        logger.notice("Concatenated \(insertedCount) of \(segments.count) segments → \(destinationURL.lastPathComponent, privacy: .public)")
        return true
    }

    enum ConcatenationError: LocalizedError {
        case noSegments
        case compositionTrackUnavailable
        case exportSessionUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSegments:
                return "No audio segments to concatenate."
            case .compositionTrackUnavailable:
                return "Couldn't create an audio composition track."
            case .exportSessionUnavailable:
                return "Couldn't create an AVAssetExportSession."
            case .exportFailed(let reason):
                return "Audio export failed: \(reason)"
            }
        }
    }
}
