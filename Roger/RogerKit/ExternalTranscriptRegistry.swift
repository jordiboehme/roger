import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "ExternalTranscriptRegistry")

/// Remembers transcripts Roger wrote outside the library ("next to the
/// source file"), so the library can still list them. Stored as JSON in
/// Application Support. Files that no longer exist are dropped on read.
public struct ExternalTranscriptRegistry: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Stored: Codable {
        var version = 1
        var paths: [String]
    }

    public static var standard: ExternalTranscriptRegistry {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ExternalTranscriptRegistry(
            fileURL: support.appendingPathComponent("Roger", isDirectory: true)
                .appendingPathComponent("external-transcripts.json")
        )
    }

    public func add(_ url: URL) throws {
        var paths = try loadForWriting()
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        try save(paths)
    }

    /// Paths that still exist. Saves the list again when some were missing.
    public func existingFiles() -> [URL] {
        let paths = load()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.count != paths.count {
            try? save(existing)
        }
        return existing.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// Paths that still exist. Never writes, so `roger-mcp` (which must only
    /// write consumer bookmarks) can call it.
    public func listedFiles() -> [URL] {
        load()
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [] }
        return stored.paths
    }

    /// Like `load()`, but a file that exists and cannot be decoded is first
    /// moved aside to `<name>.corrupt-<yyyyMMdd-HHmmss>.json`, so writing a
    /// fresh list never destroys it. Throws when it cannot be moved.
    private func loadForWriting() throws -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            // Present but unreadable: keep it and do not write over it.
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return stored.paths
        }
        let aside = corruptCopyURL()
        try FileManager.default.moveItem(at: fileURL, to: aside)
        logger.warning("Unreadable \(fileURL.lastPathComponent, privacy: .public), moved aside to \(aside.lastPathComponent, privacy: .public)")
        return []
    }

    private func corruptCopyURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = fileURL.deletingLastPathComponent()
        let base = "\(fileURL.deletingPathExtension().lastPathComponent).corrupt-\(formatter.string(from: .now))"
        var candidate = folder.appendingPathComponent("\(base).json")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix).json")
            suffix += 1
        }
        return candidate
    }

    private func save(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Stored(paths: paths)).write(to: fileURL, options: .atomic)
    }
}
