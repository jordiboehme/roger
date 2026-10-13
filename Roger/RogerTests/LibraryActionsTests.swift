import Foundation
import Testing
@testable import Roger

struct LibraryActionsTests {
    private func layout(_ root: URL) -> LibraryLayout {
        LibraryLayout(root: root)
    }

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
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
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
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["talk.mp4.md"])
    }

    @Test func meetingGoesAsWholeFolderAfterConfirmation() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic.m4a"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
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
        let plan = LibraryActions.trashPlan(for: [meeting, log], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
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
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [root], activeSessionFolder: nil)
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
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
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
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [extra], activeSessionFolder: nil)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])

        // A session folder directly in an extra folder that contains the library root.
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        try touch(outer.appendingPathComponent("transcript.md"))
        let library = outer.appendingPathComponent("Roger", isDirectory: true)
        let outerItem = LibraryFixtures.item("transcript", kind: .meeting, folder: outer.path)
        let outerPlan = LibraryActions.trashPlan(
            for: [outerItem], layout: LibraryLayout(root: library), extraFolders: [root], activeSessionFolder: nil
        )
        #expect(outerPlan.urls.isEmpty)
        #expect(outerPlan.skipped == [outerItem])
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
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])
        #expect(plan.itemCount == 0)
    }

    /// A meeting-tagged `transcript.md` in a flat log or transcript month
    /// folder must never take that month folder with it.
    @Test func flatMonthFolderIsNeverTrashed() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        for kind in ["Logs", "Transcripts"] {
            let month = root.appendingPathComponent("\(kind)/2026/10", isDirectory: true)
            try touch(month.appendingPathComponent("x.md"))
            try touch(month.appendingPathComponent("x.m4a"))
            try touch(month.appendingPathComponent("transcript.md"))
            let item = LibraryFixtures.item("transcript", kind: .meeting, folder: month.path)
            let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [], activeSessionFolder: nil)
            #expect(!plan.urls.contains { LibraryPath.canonical($0) == LibraryPath.canonical(month) })
            #expect(plan.urls.isEmpty)
            #expect(plan.skipped == [item])
        }
    }

    /// Sessions from before the library live directly in an extra folder.
    @Test func legacySessionInExtraFolderIsTrashable() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let extra = root.appendingPathComponent("Roger Recordings", isDirectory: true)
        let session = extra.appendingPathComponent("2025-01-02 10-00", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic.m4a"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(
            for: [item], layout: layout(root.appendingPathComponent("Roger")), extraFolders: [extra], activeSessionFolder: nil
        )
        #expect(plan.urls.map(\.lastPathComponent) == ["2025-01-02 10-00"])
        #expect(plan.meetingFolderCount == 1)

        // Deeper inside the extra folder it is not a session Roger wrote.
        let deep = extra.appendingPathComponent("a/b", isDirectory: true)
        try touch(deep.appendingPathComponent("transcript.md"))
        let deepItem = LibraryFixtures.item("transcript", kind: .meeting, folder: deep.path)
        let deepPlan = LibraryActions.trashPlan(
            for: [deepItem], layout: layout(root.appendingPathComponent("Roger")), extraFolders: [extra], activeSessionFolder: nil
        )
        #expect(deepPlan.urls.isEmpty)
    }

    /// Only a log in the Logs folder has a recording next to it.
    @Test func logOutsideLogsFolderLeavesM4aAlone() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let extra = root.appendingPathComponent("Notes", isDirectory: true)
        try touch(extra.appendingPathComponent("x.md"))
        try touch(extra.appendingPathComponent("x.m4a"))
        let item = LibraryFixtures.item("x", folder: extra.path)
        let plan = LibraryActions.trashPlan(
            for: [item], layout: layout(root.appendingPathComponent("Roger")), extraFolders: [extra], activeSessionFolder: nil
        )
        #expect(plan.urls.map(\.lastPathComponent) == ["x.md"])
    }

    @Test func activeSessionIsSkipped() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("s", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic-001.caf"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(for: [item], layout: layout(root), extraFolders: [root], activeSessionFolder: session)
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
        let confirmed = LibraryActions.trashPlan(for: [itemA], layout: layout(root), extraFolders: [root], activeSessionFolder: nil)
        let fresh = LibraryActions.trashPlan(for: [itemA, itemB], layout: layout(root), extraFolders: [root], activeSessionFolder: nil)
        #expect(fresh.limited(to: confirmed).urls.map(\.lastPathComponent) == ["a"])
        let nowActive = LibraryActions.trashPlan(for: [itemA], layout: layout(root), extraFolders: [root], activeSessionFolder: a)
        #expect(nowActive.limited(to: confirmed).urls.isEmpty)

        // The same folder spelled through /var and /private/var is one path.
        let spelled = LibraryActions.TrashPlan(urls: [URL(fileURLWithPath: LibraryPath.canonical(a))])
        let other = LibraryActions.TrashPlan(urls: [a])
        #expect(spelled.limited(to: other).urls.count == 1)
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

    @Test func trashSkippedMessage() {
        let item = LibraryFixtures.item("x")
        #expect(LibraryActions.trashSkippedMessage(LibraryActions.TrashPlan(urls: [item.url], itemCount: 1)) == nil)
        #expect(LibraryActions.trashSkippedMessage(LibraryActions.TrashPlan(skipped: [item]))
            == "Roger left this where it is. It does not move a meeting that is being recorded or finalised, or a folder the library depends on.")
        #expect(LibraryActions.trashSkippedMessage(LibraryActions.TrashPlan(urls: [item.url], itemCount: 1, skipped: [item]))
            == "Some items stayed where they are. Roger does not move a meeting that is being recorded or finalised, or a folder the library depends on.")
    }

    @Test func trashFailureMessage() {
        #expect(LibraryActions.trashFailureMessage([]) == nil)
        let failed = [URL(fileURLWithPath: "/RogerFixtures/a.md"), URL(fileURLWithPath: "/RogerFixtures/s")]
        #expect(LibraryActions.trashFailureMessage(failed)
            == "Some files could not be moved to the Trash: a.md, s.")
    }
}
