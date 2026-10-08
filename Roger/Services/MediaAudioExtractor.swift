import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MediaAudioExtractor")

/// Normalises a dropped media URL so Parakeet can transcribe it. Audio files
/// pass through unchanged; video files get their audio track exported to a
/// temporary `.m4a` via `AVAssetExportSession`.
enum MediaAudioExtractor {
    enum ExtractError: LocalizedError {
        case unsupportedType
        case exportFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupportedType: return "File is neither audio nor video."
            case .exportFailed(let message): return "Couldn't extract audio: \(message)"
            case .cancelled: return "Cancelled"
            }
        }
    }

    struct Prepared {
        let url: URL
        /// True if `url` points at a temp file this helper created; the caller
        /// must delete it when done.
        let isTemporary: Bool
    }

    /// The file's content type, falling back to its extension when the
    /// lookup comes back empty (files in cloud-synced folders that are not
    /// fully downloaded).
    static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
    }

    static func isVideo(_ url: URL) -> Bool {
        contentType(of: url)?.conforms(to: .movie) == true
    }

    static func prepare(source: URL) async throws -> Prepared {
        let type = contentType(of: source)

        if type?.conforms(to: .audio) == true {
            return Prepared(url: source, isTemporary: false)
        }

        if type?.conforms(to: .movie) == true {
            let extracted = try await extractAudioTrack(from: source)
            return Prepared(url: extracted, isTemporary: true)
        }

        throw ExtractError.unsupportedType
    }

    /// When and how long a dropped recording is, for the transcript's
    /// temporal frontmatter.
    struct RecordingInfo: Sendable {
        let startedAt: Date
        /// `.explicit` when the container carries a recording date,
        /// `.inferred` when it falls back to the file's creation date.
        let confidence: TranscriptFrontmatter.TemporalConfidence
        let durationSeconds: Double
        let fileModifiedAt: Date?
    }

    /// Reads the recording date from the container metadata (QuickTime
    /// creation date, the MP4 `mvhd` time). Files copied or downloaded later
    /// keep that date, while their file system dates show the copy, so the
    /// creation date of the file is only the fallback.
    static func recordingInfo(for source: URL) async -> RecordingInfo {
        let asset = AVURLAsset(url: source)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let fileValues = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])

        var embedded: Date?
        if let item = try? await asset.load(.creationDate) {
            embedded = try? await item.load(.dateValue)
        }
        if let embedded, embedded.timeIntervalSince1970 > 0 {
            return RecordingInfo(
                startedAt: embedded,
                confidence: .explicit,
                durationSeconds: duration.isFinite ? duration : 0,
                fileModifiedAt: fileValues?.contentModificationDate
            )
        }
        return RecordingInfo(
            startedAt: fileValues?.creationDate ?? fileValues?.contentModificationDate ?? .now,
            confidence: .inferred,
            durationSeconds: duration.isFinite ? duration : 0,
            fileModifiedAt: fileValues?.contentModificationDate
        )
    }

    private static func extractAudioTrack(from source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let sessionOpt = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExtractError.exportFailed("AVAssetExportSession unavailable for this file")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roger-audio-\(UUID().uuidString).m4a")

        sessionOpt.outputURL = outputURL
        sessionOpt.outputFileType = .m4a

        logger.info("Extracting audio track from \(source.lastPathComponent, privacy: .public) → \(outputURL.lastPathComponent, privacy: .public)")

        // AVAssetExportSession isn't Sendable, but it is documented thread-safe
        // enough for status readback + cancelExport. Wrap in an unchecked box so
        // Swift 6 accepts it inside the @Sendable continuation and cancellation
        // handler.
        let box = SessionBox(session: sessionOpt)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                box.session.exportAsynchronously {
                    let session = box.session
                    switch session.status {
                    case .completed:
                        continuation.resume(returning: outputURL)
                    case .cancelled:
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(throwing: ExtractError.cancelled)
                    case .failed:
                        try? FileManager.default.removeItem(at: outputURL)
                        let message = session.error?.localizedDescription ?? "unknown error"
                        continuation.resume(throwing: ExtractError.exportFailed(message))
                    default:
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(throwing: ExtractError.exportFailed("unexpected status \(session.status.rawValue)"))
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    /// AVAssetExportSession is thread-safe for the operations we use
    /// (`exportAsynchronously`, `status`, `cancelExport`) but not declared
    /// `Sendable`. This box promises Sendable so Swift 6 will let us capture
    /// it in the cancellation-aware continuation below.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(session: AVAssetExportSession) { self.session = session }
    }
}
