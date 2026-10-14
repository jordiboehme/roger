import Foundation

/// Text for values shown in settings rows.
enum SettingsFormat {
    /// "1.5 s", "30 s", "1 min", "1 min 30 s", "10 min".
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        if seconds < 60 {
            let number = seconds.formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
            return "\(number) s"
        }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// "8 hours ago", "yesterday". Always English, like the rest of the UI,
    /// whatever the region is.
    static func relative(_ date: Date, to now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.formattingContext = .middleOfSentence
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
