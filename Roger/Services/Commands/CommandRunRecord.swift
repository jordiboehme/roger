import Foundation

/// What the Commands pane and the menu bar show about a command's last run.
struct CommandRunRecord: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case running
        case succeeded
        case failed(String)
    }

    let commandID: UUID
    let commandName: String
    let startedAt: Date
    var outcome: Outcome
    var outputTail: [String] = []

    static let tailLineCount = 20

    /// The last `tailLineCount` lines that are not blank.
    static func tail(of text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(lines.suffix(tailLineCount))
    }
}
