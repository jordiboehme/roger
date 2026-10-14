import Foundation

/// Where a `get_changes` range starts.
public enum ChangeStart: Equatable, Sendable {
    /// Events with a seq greater than this (a consumer's bookmark, `since: <seq>`).
    case afterSeq(Int)
    /// Events whose `at` is at or after this time.
    case atOrAfter(Date)
    /// The fixed inclusive range.
    case range(from: Int, upTo: Int)
}

/// The four `since` forms: a seq, a day (`YYYY-MM-DD`, local midnight), an
/// RFC 3339 time or a duration (`30m`, `12h`, `3d`).
public enum SinceParser {
    public static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> ChangeStart? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy(\.isASCIIDigit), let seq = Int(text) {
            return .afterSeq(seq)
        }
        if text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: text).map { .atOrAfter(calendar.startOfDay(for: $0)) }
        }
        if let unit = text.last, "mhd".contains(unit) {
            let number = text.dropLast()
            guard !number.isEmpty, number.allSatisfy(\.isASCIIDigit), let count = Int(number) else { return nil }
            let seconds: Double = unit == "m" ? 60 : unit == "h" ? 3_600 : 86_400
            return .atOrAfter(now.addingTimeInterval(-Double(count) * seconds))
        }
        return RFC3339.date(text).map { .atOrAfter($0) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
