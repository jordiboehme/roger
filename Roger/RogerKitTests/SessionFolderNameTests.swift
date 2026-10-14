import Foundation
import Testing
@testable import RogerKit

struct SessionFolderNameTests {
    @Test func readsTheFolderNameDate() throws {
        let date = try #require(SessionFolderName.date(for: URL(fileURLWithPath: "/x/2026-10-13 09-05")))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts.year == 2026 && parts.month == 10 && parts.day == 13 && parts.hour == 9 && parts.minute == 5)
    }

    @Test func ignoresTheCounterSuffix() {
        let plain = SessionFolderName.date(for: URL(fileURLWithPath: "/x/2026-10-13 09-05"))
        let suffixed = SessionFolderName.date(for: URL(fileURLWithPath: "/x/2026-10-13 09-05 2"))
        #expect(plain != nil && plain == suffixed)
    }

    @Test func otherNamesHaveNoDate() {
        #expect(SessionFolderName.date(for: URL(fileURLWithPath: "/x/notes")) == nil)
        #expect(SessionFolderName.date(for: URL(fileURLWithPath: "/x/2026-10-13")) == nil)
    }

    @Test func displayDateIsMinutePrecise() throws {
        let date = try #require(SessionFolderName.date(for: URL(fileURLWithPath: "/x/2026-10-13 09-05")))
        #expect(SessionFolderName.displayDate(date) == "2026-10-13 09:05")
    }
}
