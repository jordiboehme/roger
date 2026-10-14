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
}
