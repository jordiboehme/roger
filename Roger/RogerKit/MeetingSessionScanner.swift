import Foundation

/// Finds meeting session folders on disk. Sessions live at
/// `<library>/Meetings/YYYY/MM/<session>/` and, for older installs, directly
/// inside extra scan folders such as `~/Documents/Roger Recordings/`.
public enum MeetingSessionScanner {
    /// A folder is a session when it holds audio chunks, archives, markers
    /// or a transcript.
    public static func isSessionFolder(_ url: URL) -> Bool {
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
    public static func isUnfinished(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let hasChunks = names.contains { $0.hasSuffix(".caf") }
        guard names.contains("transcript.md") else {
            return hasChunks || names.contains("mic.m4a") || names.contains("system.m4a")
        }
        return hasChunks && transcriptReportsFailedAudio(url.appendingPathComponent("transcript.md"))
    }

    /// True when the transcript's frontmatter has `mic_audio_failed: true`
    /// or `system_audio_failed: true`.
    public static func transcriptReportsFailedAudio(_ transcript: URL) -> Bool {
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
    public static func existingFolderPaths(_ paths: [String]) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Session folders at most `maxDepth` levels below `folder`. Does not
    /// look inside a session folder once found.
    public static func sessionFolders(in folder: URL, maxDepth: Int) -> [URL] {
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
    public static func allSessionFolders(layout: LibraryLayout, extraFolders: [URL]) -> [URL] {
        var found = sessionFolders(in: layout.kindFolder(.meetings), maxDepth: 3)
        for folder in extraFolders {
            found.append(contentsOf: sessionFolders(in: folder, maxDepth: 1))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
