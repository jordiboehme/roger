import Foundation

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case title
    case duration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .title: return "Title"
        case .duration: return "Duration"
        }
    }

    /// Date sorts group the list by day; the others show one flat list.
    var isByDate: Bool { self == .newestFirst || self == .oldestFirst }
}

enum LibraryDateFilter: Hashable, Sendable {
    case any
    case today
    case last7Days
    case last30Days
    /// Whole local days from the earlier to the later date, both included.
    case custom(from: Date, to: Date)

    /// The covered span in whole local days, end exclusive. Nil for `.any`.
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return nil }
        func back(_ days: Int) -> DateInterval? {
            calendar.date(byAdding: .day, value: -days, to: startOfToday).map { DateInterval(start: $0, end: endOfToday) }
        }
        switch self {
        case .any:
            return nil
        case .today:
            return DateInterval(start: startOfToday, end: endOfToday)
        case .last7Days:
            return back(6)
        case .last30Days:
            return back(29)
        case .custom(let a, let b):
            let start = calendar.startOfDay(for: min(a, b))
            let lastDay = calendar.startOfDay(for: max(a, b))
            guard let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    var label: String {
        switch self {
        case .any: return "Any Date"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .custom(let a, let b):
            let f = LibraryFormat.formatter("d MMM", calendar: .current)
            return "\(f.string(from: min(a, b))) - \(f.string(from: max(a, b)))"
        }
    }
}

/// What the library list shows: kind, date span, search words and order.
struct LibraryQuery: Equatable, Sendable {
    /// Nil shows every kind.
    var kind: LibraryItemKind?
    var dateFilter: LibraryDateFilter = .any
    var searchText = ""
    var sort: LibrarySort = .newestFirst

    /// Lowercased words of `searchText`. Every word must occur in the item.
    var searchTerms: [String] {
        searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func apply(to items: [LibraryItem], now: Date = .now, calendar: Calendar = .current) -> [LibraryItem] {
        let interval = dateFilter.interval(now: now, calendar: calendar)
        let terms = searchTerms
        let matching = items.filter { item in
            if let kind, item.kind != kind { return false }
            if let interval, !(item.date >= interval.start && item.date < interval.end) { return false }
            return terms.allSatisfy { item.searchText.contains($0) }
        }
        return Self.sorted(matching, by: sort)
    }

    static func sorted(_ items: [LibraryItem], by sort: LibrarySort) -> [LibraryItem] {
        items.sorted { a, b in
            switch sort {
            case .newestFirst:
                return a.date != b.date ? a.date > b.date : a.id < b.id
            case .oldestFirst:
                return a.date != b.date ? a.date < b.date : a.id < b.id
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                return order != .orderedSame ? order == .orderedAscending : a.date > b.date
            case .duration:
                switch (a.durationSeconds, b.durationSeconds) {
                case let (x?, y?) where x != y: return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.date > b.date
                }
            }
        }
    }
}
