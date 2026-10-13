import Foundation
import Testing
@testable import Roger

struct LibraryActionsTests {
    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    @Test func pathsAndFolders() {
        let a = LibraryFixtures.item("a")
        let b = LibraryFixtures.item("b")
        let meeting = LibraryFixtures.item("transcript", kind: .meeting, folder: "/RogerFixtures/Meetings/2026/10/s")
        #expect(LibraryActions.pathsText(for: [a, meeting])
            == "/RogerFixtures/Logs/2026/10/a.md\n/RogerFixtures/Meetings/2026/10/s/transcript.md")
        #expect(LibraryActions.folderURLs(for: [a, b, meeting]).map(\.path)
            == ["/RogerFixtures/Logs/2026/10", "/RogerFixtures/Meetings/2026/10/s"])
        #expect(LibraryActions.folderPathsText(for: [a, b]) == "/RogerFixtures/Logs/2026/10")
    }

    @Test func logGoesWithItsAudioAndNothingElse() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let month = root.appendingPathComponent("Logs/2026/10", isDirectory: true)
        try touch(month.appendingPathComponent("x.md"))
        try touch(month.appendingPathComponent("x.m4a"))
        try touch(month.appendingPathComponent("y.md"))
        let item = LibraryFixtures.item("x", folder: month.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [root], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["x.md", "x.m4a"])
        #expect(plan.itemCount == 1)
        #expect(!plan.needsConfirmation)
    }

    @Test func transcriptLeavesItsSourceMediaAlone() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let media = root.appendingPathComponent("talk.mp4")
        try touch(media)
        try touch(root.appendingPathComponent("talk.mp4.md"))
        let item = LibraryFixtures.item("talk.mp4", kind: .transcript, folder: root.path, audio: [media])
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["talk.mp4.md"])
    }

    @Test func meetingGoesAsWholeFolderAfterConfirmation() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic.m4a"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(
            for: [item],
            protectedFolders: [root, root.appendingPathComponent("Meetings")],
            activeSessionFolder: nil
        )
        #expect(plan.urls.map(\.lastPathComponent) == ["2026-10-13 09-00"])
        #expect(plan.meetingFolderCount == 1)
        #expect(plan.itemCount == 1)
        #expect(plan.needsConfirmation)
        #expect(plan.confirmationTitle == "Move this meeting to the Trash?")
    }

    @Test func itemCountCountsEntriesNotFiles() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let month = root.appendingPathComponent("Logs/2026/10", isDirectory: true)
        try touch(month.appendingPathComponent("x.md"))
        try touch(month.appendingPathComponent("x.m4a"))
        let session = root.appendingPathComponent("Meetings/2026/10/s", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        let log = LibraryFixtures.item("x", folder: month.path)
        let meeting = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(for: [meeting, log], protectedFolders: [root], activeSessionFolder: nil)
        #expect(plan.urls.count == 3)
        #expect(plan.itemCount == 2)
        #expect(plan.meetingFolderCount == 1)
        #expect(plan.confirmationTitle == "Move 2 items to the Trash?")

        let two = LibraryActions.TrashPlan(urls: [session, month], itemCount: 2, meetingFolderCount: 2)
        #expect(two.confirmationTitle == "Move 2 meetings to the Trash?")
    }

    @Test func unfinishedMeetingGoesAsFolder() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("s", isDirectory: true)
        try touch(session.appendingPathComponent("mic-001.caf"))
        var item = LibraryFixtures.item("x", kind: .meeting, folder: session.path, unfinished: true)
        item.url = session
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["s"])
        #expect(plan.needsConfirmation)
    }

    @Test func meetingFileOutsideASessionMovesOnlyTheFile() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let month = root.appendingPathComponent("Transcripts/2026/10", isDirectory: true)
        try touch(month.appendingPathComponent("odd.md"))
        try touch(month.appendingPathComponent("other.md"))
        let item = LibraryFixtures.item("odd", kind: .meeting, folder: month.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["odd.md"])
        #expect(!plan.needsConfirmation)
    }

    @Test func protectedFoldersAreNeverTrashed() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        // A session folder that is itself an extra scan folder.
        let extra = root.appendingPathComponent("Roger Recordings", isDirectory: true)
        try touch(extra.appendingPathComponent("transcript.md"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: extra.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [extra], activeSessionFolder: nil)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])

        // A session folder that contains the library root.
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        try touch(outer.appendingPathComponent("transcript.md"))
        let library = outer.appendingPathComponent("Roger", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let outerItem = LibraryFixtures.item("transcript", kind: .meeting, folder: outer.path)
        #expect(LibraryActions.trashPlan(for: [outerItem], protectedFolders: [library], activeSessionFolder: nil).urls.isEmpty)
    }

    /// A month folder with a stray `transcript.md` looks like a session
    /// folder, but it holds other sessions. It must never go to the Trash.
    @Test func monthFolderIsNeverTrashed() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let month = root.appendingPathComponent("Meetings/2026/10", isDirectory: true)
        try touch(month.appendingPathComponent("transcript.md"))
        try touch(month.appendingPathComponent("2026-10-13 09-00/transcript.md"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: month.path)
        let plan = LibraryActions.trashPlan(
            for: [item],
            protectedFolders: [root, root.appendingPathComponent("Meetings")],
            activeSessionFolder: nil
        )
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])
        #expect(plan.itemCount == 0)
    }

    @Test func activeSessionIsSkipped() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("s", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic-001.caf"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: session)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])
    }

    /// A meeting that became active while the question was open stays, and
    /// nothing that was not confirmed is added.
    @Test func confirmedPlanOnlyShrinks() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        try touch(a.appendingPathComponent("transcript.md"))
        try touch(b.appendingPathComponent("transcript.md"))
        let itemA = LibraryFixtures.item("transcript", kind: .meeting, folder: a.path)
        let itemB = LibraryFixtures.item("transcript", kind: .meeting, folder: b.path)
        let confirmed = LibraryActions.trashPlan(for: [itemA], protectedFolders: [], activeSessionFolder: nil)
        let fresh = LibraryActions.trashPlan(for: [itemA, itemB], protectedFolders: [], activeSessionFolder: nil)
        #expect(fresh.limited(to: confirmed).urls.map(\.lastPathComponent) == ["a"])
        let nowActive = LibraryActions.trashPlan(for: [itemA], protectedFolders: [], activeSessionFolder: a)
        #expect(nowActive.limited(to: confirmed).urls.isEmpty)
    }

    @Test func moveToTrashReportsFailuresAndTriesEveryURL() {
        let a = URL(fileURLWithPath: "/RogerFixtures/a.md")
        let b = URL(fileURLWithPath: "/RogerFixtures/b.md")
        var tried: [URL] = []
        let failed = LibraryActions.moveToTrash([a, b]) { url in
            tried.append(url)
            if url == a { throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(tried == [a, b])
        #expect(failed == [a])
    }

    @Test func trashFailureMessage() {
        #expect(LibraryActions.trashFailureMessage([]) == nil)
        let failed = [URL(fileURLWithPath: "/RogerFixtures/a.md"), URL(fileURLWithPath: "/RogerFixtures/s")]
        #expect(LibraryActions.trashFailureMessage(failed)
            == "Some files could not be moved to the Trash: a.md, s.")
    }
}
