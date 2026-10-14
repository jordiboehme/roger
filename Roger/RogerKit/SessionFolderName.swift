import Foundation

/// Meeting session folders are named `yyyy-MM-dd HH-mm` in local time, with
/// ` 1`, ` 2` ... when the name was taken.
public enum SessionFolderName {
    /// Start date from the first 16 characters of the folder name.
    public static func date(for folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.count >= 16 else { return nil }
        return folderFormatter.date(from: String(name.prefix(16)))
    }

    /// `yyyy-MM-dd HH:mm` in local time, used in meeting titles.
    public static func displayDate(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    // Made once: the library reads one folder name per meeting.
    // `DateFormatter` is thread-safe and `Sendable`.
    private static let folderFormatter = formatter("yyyy-MM-dd HH-mm")
    private static let displayFormatter = formatter("yyyy-MM-dd HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
