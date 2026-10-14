import Foundation

/// One Roger-style log entry in the five shapes other editors write:
/// CRLF, CR only, a UTF-8 BOM, UTF-16 LE with a BOM and Windows-1252.
/// Shared by RogerKitTests and RogerTests (`Roger/TestSupport`).
enum TextSample: String, CaseIterable, Sendable {
    case crlf
    case crOnly
    case utf8BOM
    case utf16LEBOM
    case windows1252

    /// What every variant decodes to: UTF-8 with LF.
    static let text = """
    ---
    type: source
    title: "Grüße aus Köln"
    tags: [log, reise]
    started_at: 2026-10-13T14:32:05+02:00
    duration_seconds: 33
    ---
    # Grüße aus Köln

    Ärger über die Lieferung, Kosten 5 €.
    Zweite Zeile.

    """

    static let title = "Grüße aus Köln"
    static let firstLine = "Ärger über die Lieferung, Kosten 5 €."
    static let startedAt = Date(timeIntervalSince1970: 1_791_894_725)

    /// The file's bytes.
    var data: Data {
        let text = Self.text
        switch self {
        case .crlf:
            return Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        case .crOnly:
            return Data(text.replacingOccurrences(of: "\n", with: "\r").utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LEBOM:
            return Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        case .windows1252:
            return text.replacingOccurrences(of: "\n", with: "\r\n").data(using: .windowsCP1252)!
        }
    }

    /// Writes the bytes to `url` (creating the folder) and returns `url`.
    @discardableResult
    func write(to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
