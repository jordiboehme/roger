import Foundation

/// Meeting session folders are named `yyyy-MM-dd HH-mm` in local time, with
/// ` 1`, ` 2` ... when the name was taken.
public enum SessionFolderName {
    /// Start date from the first 16 characters of the folder name.
    public static func date(for folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.count >= 16 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.date(from: String(name.prefix(16)))
    }

    /// `yyyy-MM-dd HH:mm` in local time, used in meeting titles.
    public static func displayDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
