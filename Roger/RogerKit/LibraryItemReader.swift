import Foundation

/// Builds `LibraryItem`s from files on disk. Never throws: a file that
/// cannot be read or parsed still becomes an item, named after the file and
/// dated by the file system, so it stays visible in the library.
public enum LibraryItemReader {
    public static let maxFirstLineLength = 200
    /// `sources` ids whose files count as the item's audio ("Open Audio").
    /// `media` is the source file of a file transcript.
    public static let audioSourceIDs: Set<String> = ["audio", "mic", "system", "media"]

    /// One Markdown file. Nil only for meeting segment files
    /// (`[meeting, segment]`), which belong to their meeting. `fallbackKind`
    /// applies when the tags do not say. `folder` overrides the item's
    /// folder (meetings: the session folder).
    public static func item(markdownAt url: URL, fallbackKind: LibraryItemKind, folder: URL? = nil) -> LibraryItem? {
        let text = (try? TextFile.read(url)) ?? ""
        let front = LibraryFrontmatterParser.parse(text)
        let tags = Set(front?.tags ?? [])
        if tags.contains("meeting") && tags.contains("segment") { return nil }

        let kind: LibraryItemKind
        if tags.contains("log") {
            kind = .log
        } else if tags.contains("meeting") && tags.contains("transcript") {
            kind = .meeting
        } else if tags.contains("transcript") {
            kind = .transcript
        } else {
            kind = fallbackKind
        }

        let body = String(LibraryFrontmatterParser.split(text).body)
        let scalars = front?.scalars ?? [:]
        let baseFolder = url.deletingLastPathComponent()
        let title = nonEmpty(scalars["title"])
            ?? firstHeading(in: body)
            ?? url.deletingPathExtension().lastPathComponent
        let audio = (front?.sources ?? [])
            .filter { audioSourceIDs.contains($0.id) }
            .map { resolve($0.resource, relativeTo: baseFolder) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        return LibraryItem(
            url: url,
            folderURL: folder ?? baseFolder,
            kind: kind,
            title: title,
            date: recordingDate(scalars) ?? fileDate(url) ?? .distantPast,
            durationSeconds: scalars["duration_seconds"].flatMap { Int($0) },
            language: nonEmpty(scalars["language"]),
            preset: nonEmpty(scalars["preset"]),
            speakerCount: scalars["speaker_count"].flatMap { Int($0) },
            screenshotCount: scalars["screenshot_count"].flatMap { Int($0) } ?? 0,
            audioFiles: audio,
            firstLine: firstLine(ofBody: body),
            searchText: (title + "\n" + body).lowercased(),
            isUnfinished: false
        )
    }

    /// The item for a meeting session folder: its `transcript.md`, or an
    /// "unfinished" item for a folder that still has audio but no
    /// transcript. Nil for a folder with neither.
    public static func meetingItem(sessionFolder folder: URL) -> LibraryItem? {
        let fm = FileManager.default
        let unfinished = MeetingSessionScanner.isUnfinished(folder)
        let transcript = folder.appendingPathComponent("transcript.md")
        if fm.fileExists(atPath: transcript.path) {
            guard var item = Self.item(markdownAt: transcript, fallbackKind: .meeting, folder: folder) else { return nil }
            item.kind = .meeting
            item.isUnfinished = unfinished
            return item
        }
        guard unfinished else { return nil }
        let markers = MeetingMarkersSummary.read(from: folder)
        let started = markers?.sessionStartedAt
            ?? SessionFolderName.date(for: folder)
            ?? fileDate(folder)
            ?? .distantPast
        let title = "Unfinished meeting \(SessionFolderName.displayDate(started))"
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        // The archives of an earlier run, then the CAF chunks of the recording.
        let archives = ["mic.m4a", "system.m4a"].filter { names.contains($0) }
        let chunks = names.filter { $0.lowercased().hasSuffix(".caf") }.sorted()
        let audio = (archives + chunks).map { folder.appendingPathComponent($0) }
        // Without markers.json the screenshots in the folder are counted.
        let screenshots = markers?.markerCount
            ?? names.filter { ItemResolver.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count
        return LibraryItem(
            url: folder,
            folderURL: folder,
            kind: .meeting,
            title: title,
            date: started,
            durationSeconds: nil,
            language: nil,
            preset: nil,
            speakerCount: nil,
            screenshotCount: screenshots,
            audioFiles: audio,
            firstLine: "Not transcribed yet.",
            searchText: title.lowercased(),
            isUnfinished: true
        )
    }

    /// First line of text worth showing in a list row: skips headings,
    /// images and meeting speaker headers, drops `**`.
    public static func firstLine(ofBody body: String) -> String {
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("![") || isSpeakerHeader(line) { continue }
            return String(line.replacingOccurrences(of: "**", with: "").prefix(maxFirstLineLength))
        }
        return ""
    }

    /// `**Speaker** [00:01:02]` or `**Speaker** [00:01:02 · 2026-10-13 09:01:02]`.
    private static func isSpeakerHeader(_ line: String) -> Bool {
        line.hasPrefix("**") && line.hasSuffix("]") && line.contains("** [")
    }

    private static func firstHeading(in body: String) -> String? {
        for raw in body.split(separator: "\n") where raw.hasPrefix("# ") {
            return nonEmpty(String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func recordingDate(_ scalars: [String: String]) -> Date? {
        if let raw = scalars["started_at"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
        }
        if let raw = scalars["source_date"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: raw)
        }
        return nil
    }

    private static func fileDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date)
    }

    /// `resource` is relative to the Markdown file's folder unless absolute.
    private static func resolve(_ resource: String, relativeTo folder: URL) -> URL {
        if resource.hasPrefix("/") { return URL(fileURLWithPath: resource) }
        return folder.appendingPathComponent(resource).standardizedFileURL
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
