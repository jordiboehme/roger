import Foundation
import Testing
@testable import Roger

struct LibraryQueryTests {
    let calendar = LibraryFixtures.calendar
    let now = LibraryFixtures.date(2026, 10, 14, 10)

    private func titles(_ query: LibraryQuery, _ items: [LibraryItem]) -> [String] {
        query.apply(to: items, now: now, calendar: calendar).map(\.title)
    }

    @Test func filtersByKind() {
        let items = [
            LibraryFixtures.item("log", kind: .log),
            LibraryFixtures.item("meeting", kind: .meeting),
            LibraryFixtures.item("talk", kind: .transcript),
        ]
        #expect(titles(LibraryQuery(kind: .meeting), items) == ["meeting"])
        #expect(titles(LibraryQuery(kind: nil), items).count == 3)
    }

    @Test func todayCoversTheLocalDay() {
        let items = [
            LibraryFixtures.item("early", date: LibraryFixtures.date(2026, 10, 14, 0, 30)),
            LibraryFixtures.item("late", date: LibraryFixtures.date(2026, 10, 14, 23, 30)),
            LibraryFixtures.item("yesterday", date: LibraryFixtures.date(2026, 10, 13, 23, 59)),
        ]
        #expect(Set(titles(LibraryQuery(dateFilter: .today), items)) == ["early", "late"])
    }

    @Test func last7DaysIncludesTodayAndSixDaysBack() {
        let items = [
            LibraryFixtures.item("in", date: LibraryFixtures.date(2026, 10, 8, 0, 1)),
            LibraryFixtures.item("out", date: LibraryFixtures.date(2026, 10, 7, 23, 59)),
        ]
        #expect(titles(LibraryQuery(dateFilter: .last7Days), items) == ["in"])
    }

    @Test func last30DaysIncludesTodayAndTwentyNineDaysBack() {
        let items = [
            LibraryFixtures.item("in", date: LibraryFixtures.date(2026, 9, 15, 0, 1)),
            LibraryFixtures.item("out", date: LibraryFixtures.date(2026, 9, 14, 23, 59)),
        ]
        #expect(titles(LibraryQuery(dateFilter: .last30Days), items) == ["in"])
    }

    @Test func customRangeIncludesTheLastDayAndAcceptsSwappedBounds() {
        let items = [
            LibraryFixtures.item("first", date: LibraryFixtures.date(2026, 10, 1, 0, 5)),
            LibraryFixtures.item("last", date: LibraryFixtures.date(2026, 10, 3, 23, 55)),
            LibraryFixtures.item("after", date: LibraryFixtures.date(2026, 10, 4, 0, 5)),
        ]
        let range = LibraryDateFilter.custom(from: LibraryFixtures.date(2026, 10, 3), to: LibraryFixtures.date(2026, 10, 1))
        #expect(Set(titles(LibraryQuery(dateFilter: range), items)) == ["first", "last"])
    }

    @Test func searchNeedsEveryWordAndIgnoresCase() {
        let items = [
            LibraryFixtures.item("a", body: "Called the Supplier about the shipment"),
            LibraryFixtures.item("b", body: "Called the plumber"),
        ]
        #expect(titles(LibraryQuery(searchText: "SUPPLIER ship"), items) == ["a"])
        #expect(titles(LibraryQuery(searchText: "called"), items).count == 2)
        #expect(titles(LibraryQuery(searchText: "supplier cat"), items).isEmpty)
        #expect(titles(LibraryQuery(searchText: "   "), items).count == 2)
    }

    @Test func sortOrders() {
        // Transcripts: their rows show the title (log rows show their text).
        let items = [
            LibraryFixtures.item("Log 10", kind: .transcript, date: LibraryFixtures.date(2026, 10, 2), duration: 30),
            LibraryFixtures.item("Log 2", kind: .transcript, date: LibraryFixtures.date(2026, 10, 3), duration: nil),
            LibraryFixtures.item("Log 1", kind: .transcript, date: LibraryFixtures.date(2026, 10, 1), duration: 90),
        ]
        #expect(titles(LibraryQuery(sort: .newestFirst), items) == ["Log 2", "Log 10", "Log 1"])
        #expect(titles(LibraryQuery(sort: .oldestFirst), items) == ["Log 1", "Log 10", "Log 2"])
        #expect(titles(LibraryQuery(sort: .title), items) == ["Log 1", "Log 2", "Log 10"])
        #expect(titles(LibraryQuery(sort: .duration), items) == ["Log 1", "Log 10", "Log 2"])
    }

    /// Log rows show their text, so title sort orders logs by that text.
    @Test func titleSortUsesTheRowTextOfLogs() {
        let zebra = LibraryFixtures.item("a", kind: .log, title: "Log 2026-10-13 09:00 - Zebra crossing", body: "Zebra crossing")
        let apple = LibraryFixtures.item("b", kind: .log, title: "Log 2026-10-13 10:00 - Apple pie", body: "Apple pie")
        let meeting = LibraryFixtures.item("c", kind: .meeting, title: "Meeting notes", body: "Budget")
        let empty = LibraryFixtures.item("d", kind: .log, title: "Log 2026-10-13 11:00", body: "")
        let sorted = LibraryQuery.sorted([zebra, apple, meeting, empty], by: .title)
        #expect(sorted.map(\.id) == [apple.id, empty.id, meeting.id, zebra.id])
    }

    @Test func unfinishedHasNoFilters() {
        #expect(!LibrarySidebarSelection.unfinished.usesFilters)
        #expect(LibrarySidebarSelection.all.usesFilters)
        #expect(LibrarySidebarSelection.kind(.log).usesFilters)
    }
}
