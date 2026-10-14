import Foundation
import os
import UniformTypeIdentifiers

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
            let allowed = Set(confirmed.urls.map { LibraryPath.canonical($0) })
            var plan = self
            plan.urls = urls.filter { allowed.contains(LibraryPath.canonical($0)) }
            return plan
        }
    }

    /// What Move to Trash moves:
    /// - a log: its `.md`, and the `.m4a` with the same name next to it
    ///   when the log is in the library's Logs folder;
    /// - a file transcript: its `.md` only, never the source media;
    /// - a meeting: its whole session folder, but only when the item is
    ///   that folder's `transcript.md` (or the folder itself when
    ///   unfinished) and `isRogerSessionFolder` says the folder is one Roger
    ///   wrote. Otherwise the meeting stays (a month folder with a stray
    ///   `transcript.md` holds other entries);
    /// - nothing inside `activeSessionFolder` (recording or finalising).
    static func trashPlan(
        for items: [LibraryItem],
        layout: LibraryLayout,
        extraFolders: [URL],
        activeSessionFolder: URL?
    ) -> TrashPlan {
        let logs = LibraryPath.canonical(layout.kindFolder(.logs))
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
                if isRogerSessionFolder(item.folderURL, layout: layout, extraFolders: extraFolders) {
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
            if item.kind == .log, LibraryPath.isPath(LibraryPath.canonical(item.url), inside: logs) {
                let audio = item.url.deletingPathExtension().appendingPathExtension("m4a")
                if FileManager.default.fileExists(atPath: audio.path) { add(audio) }
            }
        }
        return plan
    }

    /// True when `folder` is a meeting session folder Roger wrote, so it may
    /// go to the Trash whole and its extra files may be listed:
    /// - it is where Roger writes sessions: exactly `Meetings/YYYY/MM/<session>`,
    ///   or directly inside an extra folder (sessions from before the
    ///   library). In an extra folder it must also lie outside the library's
    ///   Logs and Transcripts folders and look like Roger's own: a session
    ///   folder name (`yyyy-MM-dd HH-mm`) or a `transcript.md` tagged
    ///   `meeting`;
    /// - it holds session files and no subfolders (Roger writes sessions
    ///   flat). `allowsSubfolders` drops this rule for listing extra files:
    ///   the section shows subfolders but never moves them;
    /// - it neither is nor contains the library root, a kind folder or an
    ///   extra folder.
    /// Anything else is not a session folder, so nothing in it is moved.
    static func isRogerSessionFolder(
        _ folderURL: URL,
        layout: LibraryLayout,
        extraFolders: [URL],
        allowsSubfolders: Bool = false
    ) -> Bool {
        let folder = LibraryPath.canonical(folderURL)
        let protectedFolders = [layout.root] + LibraryLayout.Kind.allCases.map { layout.kindFolder($0) } + extraFolders
        guard !protectedFolders.contains(where: { LibraryPath.isPath(LibraryPath.canonical($0), inside: folder) }) else {
            return false
        }
        let meetings = LibraryPath.canonical(layout.kindFolder(.meetings))
        let inMeetings = LibraryPath.components(of: folder, below: meetings).count == 3
        let inExtra = !inMeetings
            && extraFolders.contains { LibraryPath.components(of: folder, below: LibraryPath.canonical($0)).count == 1 }
            && ![LibraryLayout.Kind.logs, .transcripts].contains { LibraryPath.isPath(folder, inside: LibraryPath.canonical(layout.kindFolder($0))) }
            && (LibraryMigration.sessionDate(for: folderURL) != nil || hasMeetingTranscript(folderURL))
        return (inMeetings || inExtra)
            && MeetingSessionScanner.isSessionFolder(folderURL)
            && (allowsSubfolders || !hasSubfolder(folderURL))
    }

    /// True when the extra files of a retry should be looked for: the item
    /// is the `transcript.md` of a meeting session folder Roger wrote. A
    /// meeting-tagged file anywhere else (a Transcripts month folder, an
    /// extra folder) gives nothing, so other files there are never listed.
    static func listsExtraFiles(_ item: LibraryItem, layout: LibraryLayout, extraFolders: [URL]) -> Bool {
        guard item.kind == .meeting, item.hasMarkdown else { return false }
        return ownsSessionFolder(item, folder: LibraryPath.canonical(item.folderURL))
            && isRogerSessionFolder(item.folderURL, layout: layout, extraFolders: extraFolders, allowsSubfolders: true)
    }

    /// What the Extra files section says when it moved nothing because the
    /// meeting got busy: it is being recorded or finalised, or a retry
    /// started while the question was open.
    static let extraFilesBusyMessage = "Roger did not move these files. This meeting is busy right now or waits for a retry. Try again when it is done."

    /// True when the folder's `transcript.md` has `meeting` in its tags.
    private static func hasMeetingTranscript(_ folder: URL) -> Bool {
        let transcript = folder.appendingPathComponent("transcript.md")
        guard let text = try? TextFile.read(transcript) else { return false }
        return LibraryFrontmatterParser.parse(text)?.tags.contains("meeting") ?? false
    }

    /// The unfinished sessions Roger offers to finalise: only folders that
    /// `isRogerSessionFolder` accepts (the check Trash uses) and that the
    /// user did not dismiss (`dismissed` holds standardized paths). A
    /// subfolder the user added does not count against it: that rule is
    /// for Trash only.
    static func finalisable(
        _ sessions: [MeetingSession],
        layout: LibraryLayout,
        extraFolders: [URL],
        dismissed: Set<String>
    ) -> [MeetingSession] {
        sessions.filter { session in
            !dismissed.contains(session.folder.standardizedFileURL.path)
                && isRogerSessionFolder(session.folder, layout: layout, extraFolders: extraFolders, allowsSubfolders: true)
        }
    }

    enum MediaOpening: Equatable {
        /// Open it in the default app.
        case open
        /// Only show it in the Finder.
        case reveal
    }

    /// How "Open Audio" handles a file: only audio or video is opened, so a
    /// `sources` entry can never start a script or an app. The file the URL
    /// points to (after symlinks) must be audio or video too.
    static func mediaOpening(for url: URL) -> MediaOpening {
        let target = URL(fileURLWithPath: LibraryPath.canonical(url))
        let isMedia = [url, target].allSatisfy { candidate in
            guard let type = UTType(filenameExtension: candidate.pathExtension) else { return false }
            return type.conforms(to: .audiovisualContent)
        }
        return isMedia ? .open : .reveal
    }

    /// True when a screenshot may be opened in Preview: it is no symlink and
    /// it still lies inside `folder` (the folder of the Markdown file).
    /// Checked again right before opening, as the file may have changed.
    static func mayOpenImage(_ url: URL, inside folder: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true
        else { return false }
        return LibraryPath.isPath(LibraryPath.canonical(url), inside: LibraryPath.canonical(folder))
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

    /// Why items stayed where they are; nil when none did.
    static func trashSkippedMessage(_ plan: TrashPlan) -> String? {
        guard !plan.skipped.isEmpty else { return nil }
        if plan.urls.isEmpty {
            return "Roger left this where it is. It does not move a meeting that is being recorded or finalised, or a folder the library depends on."
        }
        return "Some items stayed where they are. Roger does not move a meeting that is being recorded or finalised, or a folder the library depends on."
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
