import Foundation
import Testing
@testable import Roger

struct LibraryDayGroupingTests {
    let calendar = LibraryFixtures.calendar
    let now = LibraryFixtures.date(2026, 10, 14, 10)

    @Test func dayHeaders() {
        let items = [
            LibraryFixtures.item("a", date: LibraryFixtures.date(2026, 10, 14, 9)),
            LibraryFixtures.item("b", date: LibraryFixtures.date(2026, 10, 14, 8)),
            LibraryFixtures.item("c", date: LibraryFixtures.date(2026, 10, 13, 9)),
            LibraryFixtures.item("d", date: LibraryFixtures.date(2026, 10, 12, 9)),
            LibraryFixtures.item("e", date: LibraryFixtures.date(2025, 10, 12, 9)),
        ]
        let sections = LibraryDayGrouping.sections(items, sort: .newestFirst, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Mon, 12 Oct", "Sun, 12 Oct 2025"])
        #expect(sections[0].items.map(\.title) == ["a", "b"])
    }

    @Test func nonDateSortsAreOneSectionWithoutHeader() {
        let items = [LibraryFixtures.item("a"), LibraryFixtures.item("b", date: LibraryFixtures.date(2026, 1, 1))]
        let sections = LibraryDayGrouping.sections(items, sort: .title, now: now, calendar: calendar)
        #expect(sections.count == 1)
        #expect(sections[0].title == "")
        #expect(sections[0].items.count == 2)
    }

    @Test func noItemsNoSections() {
        #expect(LibraryDayGrouping.sections([], sort: .newestFirst, now: now, calendar: calendar).isEmpty)
    }

    @Test func durations() {
        #expect(LibraryFormat.duration(0) == "0 s")
        #expect(LibraryFormat.duration(33) == "33 s")
        #expect(LibraryFormat.duration(60) == "1 min")
        #expect(LibraryFormat.duration(754) == "13 min")
        #expect(LibraryFormat.duration(3590) == "1 h")
        #expect(LibraryFormat.duration(3600) == "1 h")
        #expect(LibraryFormat.duration(3900) == "1 h 5 min")
    }

    @Test func metadataLineForALog() {
        let item = LibraryFixtures.item(
            "x", date: LibraryFixtures.date(2026, 10, 13, 14, 32), duration: 33, language: "de", preset: "Log"
        )
        #expect(LibraryFormat.metadataLine(for: item, calendar: calendar) == "Tue, 13 Oct 2026 · 14:32 · 33 s · de · Log")
    }

    @Test func metadataLineForAMeeting() {
        let item = LibraryFixtures.item(
            "x", kind: .meeting, date: LibraryFixtures.date(2026, 10, 13, 9), duration: 3900, speakers: 1
        )
        #expect(LibraryFormat.metadataLine(for: item, calendar: calendar) == "Tue, 13 Oct 2026 · 09:00 · 1 h 5 min · 1 speaker")
    }
}
