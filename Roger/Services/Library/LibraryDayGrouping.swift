import Foundation

/// One day of the library list.
struct LibraryDaySection: Identifiable, Equatable, Sendable {
    /// Start of the local day; `.distantPast` for the single flat section.
    let id: Date
    /// "Today", "Yesterday", "Mon, 12 Oct"; empty for the flat section.
    let title: String
    var items: [LibraryItem]
}

enum LibraryDayGrouping {
    /// Consecutive items of the same local day form one section, in the
    /// order given. Title and duration sorts give one section without a
    /// title, so the order the user picked is kept.
    static func sections(
        _ items: [LibraryItem],
        sort: LibrarySort,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [LibraryDaySection] {
        guard !items.isEmpty else { return [] }
        guard sort.isByDate else { return [LibraryDaySection(id: .distantPast, title: "", items: items)] }
        var result: [LibraryDaySection] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if result.last?.id == day {
                result[result.count - 1].items.append(item)
            } else {
                result.append(LibraryDaySection(id: day, title: title(for: day, now: now, calendar: calendar), items: [item]))
            }
        }
        return result
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return LibraryFormat.formatter(sameYear ? "EEE, d MMM" : "EEE, d MMM yyyy", calendar: calendar).string(from: day)
    }
}

/// Display strings for the library window. English only, like the rest of Roger's UI.
enum LibraryFormat {
    /// "33 s", "13 min", "1 h", "1 h 5 min".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 {
            let minutes = Int((Double(seconds) / 60).rounded())
            return minutes >= 60 ? "1 h" : "\(minutes) min"
        }
        var hours = seconds / 3600
        var minutes = Int((Double(seconds % 3600) / 60).rounded())
        if minutes == 60 {
            hours += 1
            minutes = 0
        }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// "14:32".
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    /// "Tue, 13 Oct 2026".
    static func longDate(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("EEE, d MMM yyyy", calendar: calendar).string(from: date)
    }

    /// "Tue, 13 Oct 2026 · 14:32 · 33 s · de · Log · 2 speakers". Parts
    /// that are unknown are left out. Meetings always show the speaker count.
    static func metadataLine(for item: LibraryItem, calendar: Calendar = .current) -> String {
        var parts = [longDate(item.date, calendar: calendar), time(item.date, calendar: calendar)]
        if let seconds = item.durationSeconds { parts.append(duration(seconds)) }
        if let language = item.language { parts.append(language) }
        if let preset = item.preset { parts.append(preset) }
        if let speakers = item.speakerCount, item.kind == .meeting || speakers > 1 {
            parts.append("\(speakers) speaker\(speakers == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }
}
