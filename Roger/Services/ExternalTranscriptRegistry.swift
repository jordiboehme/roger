import Foundation

/// Remembers transcripts Roger wrote outside the library ("next to the
/// source file"), so the library can still list them. Stored as JSON in
/// Application Support. Files that no longer exist are dropped on read.
struct ExternalTranscriptRegistry {
    let fileURL: URL

    private struct Stored: Codable {
        var version = 1
        var paths: [String]
    }

    static var standard: ExternalTranscriptRegistry {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ExternalTranscriptRegistry(
            fileURL: support.appendingPathComponent("Roger", isDirectory: true)
                .appendingPathComponent("external-transcripts.json")
        )
    }

    func add(_ url: URL) throws {
        var paths = load()
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        try save(paths)
    }

    /// Paths that still exist. Saves the list again when some were missing.
    func existingFiles() -> [URL] {
        let paths = load()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.count != paths.count {
            try? save(existing)
        }
        return existing.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [] }
        return stored.paths
    }

    private func save(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Stored(paths: paths)).write(to: fileURL, options: .atomic)
    }
}
