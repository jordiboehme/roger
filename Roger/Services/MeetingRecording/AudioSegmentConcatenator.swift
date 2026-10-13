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

    /// Which input chunks went into the archive. Every chunk lands in
    /// exactly one list.
    struct Result: Equatable, Sendable {
        /// Inserted into the archive.
        var inserted: [URL] = []
        /// Readable but without audio (zero frames): nothing to lose.
        var empty: [URL] = []
        /// Skipped because they could not be read (load, track or insert
        /// failed). Their audio is not in the archive.
        var unreadable: [URL] = []

        /// True when an archive was written.
        var wrote: Bool { !inserted.isEmpty }
    }

    /// Concatenates `segments` (in order) into `destinationURL` (.m4a). When
    /// no chunk could be inserted, no file is created and `wrote` is false;
    /// the caller should treat the track as missing. Throws on actual encode
    /// failure.
    @discardableResult
    static func concatenate(segments: [URL], destinationURL: URL) async throws -> Result {
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
        var result = Result()
        for url in segments {
            let asset = AVURLAsset(url: url)
            let audioTracks: [AVAssetTrack]
            do {
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                logger.warning("Segment failed to load tracks, skipping: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result.unreadable.append(url)
                continue
            }
            guard let sourceTrack = audioTracks.first else {
                logger.warning("Segment has no audio track, skipping: \(url.lastPathComponent, privacy: .public)")
                result.unreadable.append(url)
                continue
            }
            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                logger.warning("Segment failed to load duration, skipping: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result.unreadable.append(url)
                continue
            }
            let durationSeconds = CMTimeGetSeconds(duration)
            // CAF chunks that never received any audio (e.g. a recording with
            // nothing playing on the system out) are written with a header
            // but zero frames. AVMutableComposition refuses to insert a
            // zero-length range — skip these silently.
            guard durationSeconds.isFinite, durationSeconds > 0.01 else {
                logger.info("Segment has zero duration, skipping: \(url.lastPathComponent, privacy: .public)")
                result.empty.append(url)
                continue
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try track.insertTimeRange(range, of: sourceTrack, at: insertAt)
            } catch {
                logger.warning("Segment insertTimeRange failed, skipping: \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result.unreadable.append(url)
                continue
            }
            insertAt = CMTimeAdd(insertAt, duration)
            result.inserted.append(url)
            logger.debug("Concatenated \(url.lastPathComponent, privacy: .public) (\(durationSeconds)s)")
        }

        // Nothing inserted (all empty or unreadable): nothing to encode.
        // Caller treats this as "no track" and the rest of the pipeline reads
        // the missing m4a as `present == false`.
        guard result.wrote else {
            logger.info("No usable input segments (\(result.empty.count) empty, \(result.unreadable.count) unreadable), skipping encode for \(destinationURL.lastPathComponent, privacy: .public)")
            return result
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
        logger.notice("Concatenated \(result.inserted.count) of \(segments.count) segments → \(destinationURL.lastPathComponent, privacy: .public)")
        return result
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
