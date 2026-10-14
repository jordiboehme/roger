import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryLayout")

/// Folder layout of Roger's library: one root with `Logs/`, `Meetings/` and
/// `Transcripts/`, each split into `YYYY/MM/` by the local recording time.
/// The single place that knows where Roger's files go.
public struct LibraryLayout: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        case logs = "Logs"
        case meetings = "Meetings"
        case transcripts = "Transcripts"
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Documents/Roger/`.
    public static var defaultRoot: URL {
        documents.appendingPathComponent("Roger", isDirectory: true)
    }

    /// Where meetings went before the library existed: `~/Documents/Roger Recordings/`.
    public static var legacyRecordingsFolder: URL {
        documents.appendingPathComponent("Roger Recordings", isDirectory: true)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    /// Creates the root when it is the default `~/Documents/Roger/` and
    /// does not exist yet (first launch). A custom root that is missing is
    /// left alone: it may be on a drive that is not connected. True when
    /// the root exists afterwards. A failure to create the default root is
    /// logged.
    @discardableResult
    public static func createRootIfDefault(_ layout: LibraryLayout, defaultRoot: URL = LibraryLayout.defaultRoot) -> Bool {
        let fm = FileManager.default
        if isFolder(layout.root) { return true }
        guard layout.root.standardizedFileURL.path == defaultRoot.standardizedFileURL.path else { return false }
        do {
            try fm.createDirectory(at: layout.root, withIntermediateDirectories: true)
            return true
        } catch {
            let path = layout.root.path
            logger.warning("Could not create the library folder \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// True when `url` exists and is a folder (a plain file is not a root).
    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Makes sure writers may create month and session folders: the root
    /// exists, or it is the default root and can be created. A missing
    /// custom root is never created (it may be on a drive that is not
    /// connected); this throws `LibraryRootMissingError` instead.
    public static func prepareRootForWriting(_ layout: LibraryLayout, defaultRoot: URL = LibraryLayout.defaultRoot) throws {
        if createRootIfDefault(layout, defaultRoot: defaultRoot) { return }
        throw LibraryRootMissingError(path: layout.root.path)
    }

    public func kindFolder(_ kind: Kind) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// `<root>/<Kind>/YYYY/MM/` for the local month of `date`.
    public func monthFolder(_ kind: Kind, for date: Date, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        return kindFolder(kind)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
    }
}

/// The library folder is missing and Roger must not create it.
public struct LibraryRootMissingError: LocalizedError, Equatable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
    public var errorDescription: String? {
        "The library folder \(path) is missing. Connect the drive or choose another folder in Settings."
    }
}
