import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryActions")

/// The file side of the library actions. Nothing here deletes: removal
/// goes through the Trash, and `trashPlan` decides exactly what may go.
enum LibraryActions {
    /// The Markdown files (meetings: `transcript.md`). An unfinished meeting
    /// without a transcript gives its session folder. Used for Drag, Copy
    /// Path, Open and Reveal in Finder.
    static func fileURLs(for items: [LibraryItem]) -> [URL] {
        items.map(\.url)
    }

    /// POSIX paths, one per line, ready to paste into an agent or a terminal.
    static func pathsText(for items: [LibraryItem]) -> String {
        fileURLs(for: items).map(\.path).joined(separator: "\n")
    }

    /// Meeting session folders, or the folder holding a log or transcript
    /// (its month folder in the library). Each folder once, in order.
    static func folderURLs(for items: [LibraryItem]) -> [URL] {
        var seen = Set<String>()
        return items.map(\.folderURL).filter { seen.insert($0.path).inserted }
    }

    static func folderPathsText(for items: [LibraryItem]) -> String {
        folderURLs(for: items).map(\.path).joined(separator: "\n")
    }

    struct TrashPlan: Equatable {
        var urls: [URL] = []
        /// Entries that move (a log with its `.m4a` is one entry).
        var itemCount = 0
        /// Whole meeting folders in `urls`; they need a confirmation.
        var meetingFolderCount = 0
        /// Items that stay: the active meeting, protected folders, nothing to move.
        var skipped: [LibraryItem] = []
        var needsConfirmation: Bool { meetingFolderCount > 0 }

        /// Title of the question asked before meeting folders go.
        var confirmationTitle: String {
            if itemCount == meetingFolderCount {
                return itemCount == 1 ? "Move this meeting to the Trash?" : "Move \(itemCount) meetings to the Trash?"
            }
            return "Move \(itemCount) items to the Trash?"
        }

        /// This plan, keeping only URLs that `confirmed` also has. Used
        /// after the confirmation, with a fresh plan for the same items, so
        /// nothing moves that the user did not confirm or that became
        /// active meanwhile. The counts stay those of this plan.
        func limited(to confirmed: TrashPlan) -> TrashPlan {
            let allowed = Set(confirmed.urls.map(\.path))
            var plan = self
            plan.urls = urls.filter { allowed.contains($0.path) }
            return plan
        }
    }

    /// What Move to Trash moves:
    /// - a log: its `.md` and the `.m4a` with the same name next to it;
    /// - a file transcript: its `.md` only, never the source media;
    /// - a meeting: its whole session folder, but only when the item is
    ///   that folder's `transcript.md` (or the folder itself when
    ///   unfinished), the folder is a session folder without subfolders
    ///   (Roger writes sessions flat; a month folder with a stray
    ///   `transcript.md` holds other sessions), and it neither is nor
    ///   contains one of `protectedFolders` (library root, kind folders,
    ///   extra scan folders); otherwise the meeting stays;
    /// - nothing inside `activeSessionFolder` (recording or finalising).
    static func trashPlan(for items: [LibraryItem], protectedFolders: [URL], activeSessionFolder: URL?) -> TrashPlan {
        let protected = protectedFolders.map { LibraryPath.canonical($0) }
        let active = activeSessionFolder.map { LibraryPath.canonical($0) }
        var plan = TrashPlan()
        var seen = Set<String>()
        /// True when the URL was not in the plan yet.
        @discardableResult func add(_ url: URL) -> Bool {
            guard seen.insert(LibraryPath.canonical(url)).inserted else { return false }
            plan.urls.append(url)
            return true
        }
        for item in items {
            let folder = LibraryPath.canonical(item.folderURL)
            if let active, folder == active || LibraryPath.isPath(LibraryPath.canonical(item.url), inside: active) {
                plan.skipped.append(item)
                continue
            }
            if item.kind == .meeting, ownsSessionFolder(item, folder: folder) {
                let safe = MeetingSessionScanner.isSessionFolder(item.folderURL)
                    && !hasSubfolder(item.folderURL)
                    && !protected.contains { LibraryPath.isPath($0, inside: folder) }
                if safe {
                    if add(item.folderURL) {
                        plan.itemCount += 1
                        plan.meetingFolderCount += 1
                    }
                } else {
                    plan.skipped.append(item)
                }
                continue
            }
            guard item.hasMarkdown else {
                plan.skipped.append(item)
                continue
            }
            if add(item.url) { plan.itemCount += 1 }
            if item.kind == .log {
                let audio = item.url.deletingPathExtension().appendingPathExtension("m4a")
                if FileManager.default.fileExists(atPath: audio.path) { add(audio) }
            }
        }
        return plan
    }

    /// Moves each URL to the Trash and returns the ones that failed. Tries
    /// every URL even after a failure.
    @discardableResult
    static func moveToTrash(
        _ urls: [URL],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [URL] {
        var failed: [URL] = []
        for url in urls {
            do {
                try trash(url)
            } catch {
                logger.error("Could not move \(url.lastPathComponent, privacy: .public) to the Trash: \(error.localizedDescription, privacy: .public)")
                failed.append(url)
            }
        }
        return failed
    }

    /// What to tell the user about URLs `moveToTrash` could not move; nil
    /// when all of them went.
    static func trashFailureMessage(_ failed: [URL]) -> String? {
        guard !failed.isEmpty else { return nil }
        return "Some files could not be moved to the Trash: \(failed.map(\.lastPathComponent).joined(separator: ", "))."
    }

    /// True when the folder holds a directory (hidden ones and symlinks to
    /// directories included), or cannot be read.
    private static func hasSubfolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return true }
        return names.contains { name in
            var isDirectory: ObjCBool = false
            // fileExists follows symlinks, so a link to a folder counts.
            return fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// The item is its session's `transcript.md`, or (unfinished) the session folder itself.
    private static func ownsSessionFolder(_ item: LibraryItem, folder: String) -> Bool {
        if item.hasMarkdown {
            return item.url.lastPathComponent == "transcript.md"
                && LibraryPath.canonical(item.url.deletingLastPathComponent()) == folder
        }
        return LibraryPath.canonical(item.url) == folder
    }
}
