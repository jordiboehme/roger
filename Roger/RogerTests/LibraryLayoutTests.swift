import Foundation
import Testing
@testable import Roger

struct LibraryLayoutTests {
    let root = URL(fileURLWithPath: "/tmp/RogerLib", isDirectory: true)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    @Test func kindFolders() {
        let layout = LibraryLayout(root: root)
        #expect(layout.kindFolder(.logs).path == "/tmp/RogerLib/Logs")
        #expect(layout.kindFolder(.meetings).path == "/tmp/RogerLib/Meetings")
        #expect(layout.kindFolder(.transcripts).path == "/tmp/RogerLib/Transcripts")
    }

    @Test func monthFolderIsZeroPadded() {
        let layout = LibraryLayout(root: root)
        #expect(layout.monthFolder(.logs, for: date(2026, 3, 5)).path == "/tmp/RogerLib/Logs/2026/03")
        #expect(layout.monthFolder(.meetings, for: date(2026, 10, 13)).path == "/tmp/RogerLib/Meetings/2026/10")
    }

    @Test func defaultRootIsRogerInDocuments() {
        #expect(LibraryLayout.defaultRoot.lastPathComponent == "Roger")
        #expect(LibraryLayout.defaultRoot.deletingLastPathComponent().lastPathComponent == "Documents")
        #expect(LibraryLayout.legacyRecordingsFolder.lastPathComponent == "Roger Recordings")
    }
}
