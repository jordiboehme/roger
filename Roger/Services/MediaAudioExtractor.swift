import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MediaAudioExtractor")

/// Normalises a dropped media URL so WhisperKit can transcribe it. Audio files
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

    static func prepare(source: URL) async throws -> Prepared {
        let type = try? source.resourceValues(forKeys: [.contentTypeKey]).contentType

        if type?.conforms(to: .audio) == true {
            return Prepared(url: source, isTemporary: false)
        }

        if type?.conforms(to: .movie) == true {
            let extracted = try await extractAudioTrack(from: source)
            return Prepared(url: extracted, isTemporary: true)
        }

        throw ExtractError.unsupportedType
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
