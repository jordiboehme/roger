import Foundation

/// Finds meeting session folders on disk. Sessions live at
/// `<library>/Meetings/YYYY/MM/<session>/` and, for older installs, directly
/// inside extra scan folders such as `~/Documents/Roger Recordings/`.
enum MeetingSessionScanner {
    /// A folder is a session when it holds audio chunks, archives, markers
    /// or a transcript.
    static func isSessionFolder(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { name in
            name.hasSuffix(".caf")
                || name == "transcript.md"
                || name == "markers.json"
                || name == "mic.m4a"
                || name == "system.m4a"
        }
    }

    /// A session is unfinished when it has no transcript.md yet but still
    /// has audio to transcribe: CAF chunks, or the mic.m4a/system.m4a
    /// archives left behind when an earlier finalisation encoded the chunks
    /// and then stopped (model not loaded, transcription failed).
    ///
    /// A session with a transcript is also unfinished when that transcript
    /// says a track's audio failed (`mic_audio_failed` or
    /// `system_audio_failed`) and CAF chunks are still there to retry.
    static func isUnfinished(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let hasChunks = names.contains { $0.hasSuffix(".caf") }
        guard names.contains("transcript.md") else {
            return hasChunks || names.contains("mic.m4a") || names.contains("system.m4a")
        }
        return hasChunks && transcriptReportsFailedAudio(url.appendingPathComponent("transcript.md"))
    }

    /// True when the transcript's frontmatter has `mic_audio_failed: true`
    /// or `system_audio_failed: true`.
    static func transcriptReportsFailedAudio(_ transcript: URL) -> Bool {
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---" else { return false }
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line == "mic_audio_failed: true" || line == "system_audio_failed: true" { return true }
        }
        return false
    }

    /// The paths in `paths` that still exist (used to prune stored
    /// dismissals of recovery sessions).
    static func existingFolderPaths(_ paths: [String]) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Session folders at most `maxDepth` levels below `folder`. Does not
    /// look inside a session folder once found.
    static func sessionFolders(in folder: URL, maxDepth: Int) -> [URL] {
        guard maxDepth > 0 else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [URL] = []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if isSessionFolder(child) {
                result.append(child)
            } else {
                result.append(contentsOf: sessionFolders(in: child, maxDepth: maxDepth - 1))
            }
        }
        return result
    }

    /// All sessions: the library's `Meetings/YYYY/MM/` tree plus sessions
    /// stored directly in each extra folder. An extra folder may overlap the
    /// library tree, so each session is listed once (first spelling wins).
    static func allSessionFolders(layout: LibraryLayout, extraFolders: [URL]) -> [URL] {
        var found = sessionFolders(in: layout.kindFolder(.meetings), maxDepth: 3)
        for folder in extraFolders {
            found.append(contentsOf: sessionFolders(in: folder, maxDepth: 1))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

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
