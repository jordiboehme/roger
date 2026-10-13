import Foundation
@testable import Roger

/// Library items that live only in memory. Paths start with
/// `/RogerFixtures`, which does not exist, so `LibraryPath.canonical`
/// leaves them unchanged.
enum LibraryFixtures {
    /// Fixed time zone so day boundaries do not depend on the machine.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func item(
        _ name: String,
        kind: LibraryItemKind = .log,
        title: String? = nil,
        date: Date = LibraryFixtures.date(2026, 10, 13),
        duration: Int? = nil,
        body: String = "",
        folder: String = "/RogerFixtures/Logs/2026/10",
        audio: [URL] = [],
        speakers: Int? = nil,
        language: String? = nil,
        preset: String? = nil,
        unfinished: Bool = false
    ) -> LibraryItem {
        let title = title ?? name
        return LibraryItem(
            url: URL(fileURLWithPath: "\(folder)/\(name).md"),
            folderURL: URL(fileURLWithPath: folder, isDirectory: true),
            kind: kind,
            title: title,
            date: date,
            durationSeconds: duration,
            language: language,
            preset: preset,
            speakerCount: speakers,
            screenshotCount: 0,
            audioFiles: audio,
            firstLine: body,
            searchText: (title + "\n" + body).lowercased(),
            isUnfinished: unfinished
        )
    }
}
