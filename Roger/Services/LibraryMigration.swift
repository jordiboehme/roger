import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryMigration")

/// Moves meeting sessions from the pre-library folder
/// (`~/Documents/Roger Recordings/<session>`) into
/// `<library>/Meetings/YYYY/MM/<session>`.
enum LibraryMigration {
    struct Move: Equatable {
        let source: URL
        let destinationFolder: URL
    }

    /// Start date from a session folder name (`yyyy-MM-dd HH-mm`, maybe with
    /// a ` 1` style suffix).
    static func sessionDate(for folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.count >= 16 else { return nil }
        return MeetingSession.folderNameFormatter.date(from: String(name.prefix(16)))
    }

    static func plan(sessionFolders: [URL], layout: LibraryLayout) -> [Move] {
        sessionFolders.map { folder in
            let date = sessionDate(for: folder)
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? Date()
            return Move(source: folder, destinationFolder: layout.monthFolder(.meetings, for: date))
        }
    }

    /// Moves each session. A name that is taken gets ` 1`, ` 2` … Returns
    /// the new folder URLs and the moves that failed (left in place).
    static func execute(_ moves: [Move]) -> (moved: [URL], failed: [Move]) {
        let fm = FileManager.default
        var moved: [URL] = []
        var failed: [Move] = []
        for move in moves {
            do {
                try fm.createDirectory(at: move.destinationFolder, withIntermediateDirectories: true)
                let base = move.source.lastPathComponent
                var target = move.destinationFolder.appendingPathComponent(base, isDirectory: true)
                var suffix = 1
                while fm.fileExists(atPath: target.path) {
                    target = move.destinationFolder.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
                    suffix += 1
                }
                try fm.moveItem(at: move.source, to: target)
                moved.append(target)
            } catch {
                logger.error("Could not move \(move.source.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(move)
            }
        }
        return (moved, failed)
    }
}
