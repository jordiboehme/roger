import Foundation

/// Where finalisation gets the audio for one track (mic or system).
enum MeetingTrackSource: Equatable, Sendable {
    /// Encode these CAF chunks into the archive (the normal path).
    case chunks([URL])
    /// No chunks, but the archive from an earlier finalisation exists: use it
    /// as is. It may be the only copy of the audio, so it must not be
    /// re-encoded, overwritten or deleted.
    case existingArchive
    /// Nothing recorded for this track.
    case absent

    static func resolve(chunks: [URL], archive: URL) -> MeetingTrackSource {
        if !chunks.isEmpty { return .chunks(chunks) }
        return FileManager.default.fileExists(atPath: archive.path) ? .existingArchive : .absent
    }
}

/// How encoding one track's CAF chunks into its archive went.
enum MeetingTrackEncodeOutcome: Equatable, Sendable {
    /// The concatenator ran; the result says which chunks it used.
    case encoded(AudioSegmentConcatenator.Result)
    /// The encode threw.
    case failed

    /// True when the track's audio could not be saved: the encode threw, or
    /// nothing was written and some chunks could not be read.
    var isFailure: Bool {
        switch self {
        case .failed: return true
        case .encoded(let result): return !result.wrote && !result.unreadable.isEmpty
        }
    }

    /// True when some of the track's audio is not in its archive and its
    /// chunks were kept: a failure, or an archive written without the
    /// unreadable chunks.
    var needsRetry: Bool {
        switch self {
        case .failed: return true
        case .encoded(let result): return !result.unreadable.isEmpty
        }
    }

    /// Chunks that may be deleted now: the ones whose audio is safe in the
    /// archive, and empty ones (no audio to lose). Unreadable chunks always
    /// stay, and after a failure everything stays, so a later recovery can
    /// try again.
    func deletableChunks(archiveExists: Bool) -> [URL] {
        guard case .encoded(let result) = self, !isFailure else { return [] }
        if result.wrote {
            return archiveExists ? result.inserted + result.empty : []
        }
        return result.empty
    }
}
