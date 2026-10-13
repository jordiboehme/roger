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
    static func isUnfinished(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard !names.contains("transcript.md") else { return false }
        return names.contains { name in
            name.hasSuffix(".caf") || name == "mic.m4a" || name == "system.m4a"
        }
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
