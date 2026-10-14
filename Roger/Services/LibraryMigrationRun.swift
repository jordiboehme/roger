import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryMigration")

/// The first-launch move of pre-library meetings into the library, without
/// the alert: `ask` is the "Move your meetings?" question. Folders that
/// stay in place become extra scan folders, so their meetings are still
/// found.
struct LibraryMigrationRun {
    struct Input {
        let layout: LibraryLayout
        let extraFolders: [URL]
        /// The custom file transcript folder of older versions, if any.
        let legacyTranscriptFolder: URL?
        /// The custom meetings folder of older versions, else `~/Documents/Roger Recordings/`.
        let legacyMeetingsFolder: URL
        /// The root that may be created when missing. Tests pass a temp folder.
        var defaultRoot: URL = LibraryLayout.defaultRoot
    }

    struct Result: Equatable {
        /// The extra scan folders afterwards.
        var extraFolders: [URL]
        /// Session folders that now live in the library.
        var moved: [URL] = []
        /// Sessions that could not be moved (they stay in place).
        var failedCount = 0
        /// True when `ask` was called.
        var asked = false
        /// True when the migration is done: it moved, the user kept the
        /// meetings in place or there was nothing to move. False when the
        /// library folder was missing; it is offered again next launch.
        var finished = true
    }

    /// `ask(sessionCount, folder)` returns true for Move. It is called only
    /// when the old folder has sessions, lies outside the library and the
    /// library folder is there (a missing custom folder is never created).
    @MainActor
    static func run(_ input: Input, ask: (Int, URL) -> Bool) -> Result {
        var extras = input.extraFolders
        func addExtra(_ url: URL) {
            if !extras.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                extras.append(url)
            }
        }
        if let transcripts = input.legacyTranscriptFolder {
            addExtra(transcripts)
        }
        var result = Result(extraFolders: [])
        let layout = input.layout
        let old = input.legacyMeetingsFolder
        let sessions = MeetingSessionScanner.sessionFolders(in: old, maxDepth: 1)
        if !sessions.isEmpty, !LibraryMigration.isInsideLibrary(old, layout: layout) {
            if !LibraryMigration.isReadyToMigrate(layout: layout, defaultRoot: input.defaultRoot) {
                // A missing custom library folder (drive not connected) is
                // never created: keep the meetings in place and still find them.
                logger.warning("Library migration skipped: the library folder \(layout.root.path, privacy: .public) is missing")
                result.finished = false
                addExtra(old)
            } else {
                result.asked = true
                if ask(sessions.count, old) {
                    do {
                        let outcome = try LibraryMigration.execute(
                            LibraryMigration.plan(sessionFolders: sessions, layout: layout),
                            layout: layout,
                            defaultRoot: input.defaultRoot
                        )
                        result.moved = outcome.moved
                        result.failedCount = outcome.failed.count
                        if !outcome.failed.isEmpty { addExtra(old) }
                    } catch {
                        logger.warning("Library migration skipped: \(error.localizedDescription, privacy: .public)")
                        result.finished = false
                        addExtra(old)
                    }
                } else {
                    addExtra(old)
                }
            }
        }
        result.extraFolders = extras
        return result
    }
}
