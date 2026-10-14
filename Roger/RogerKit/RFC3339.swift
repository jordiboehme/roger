import Foundation

/// RFC 3339 timestamps with the local offset (`2026-10-13T14:32:41+02:00`).
public enum RFC3339 {
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Accepts any offset or `Z`, with or without fractional seconds.
    public static func date(_ text: String) -> Date? {
        plain.date(from: text) ?? fractional.date(from: text)
    }

    // Made once: the change log parses one date per event. Formatters are
    // thread-safe on macOS, and these two are never changed after they are
    // made; `ISO8601DateFormatter` is not marked `Sendable`, hence the
    // `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
