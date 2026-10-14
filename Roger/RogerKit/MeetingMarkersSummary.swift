import Foundation

/// What the library needs from a session's `markers.json`: when the session
/// started and how many screenshots were dropped. Reads only these two
/// fields, so it does not depend on the app's checkpoint types.
public struct MeetingMarkersSummary: Equatable, Sendable {
    public let sessionStartedAt: Date
    public let markerCount: Int

    private struct File: Decodable {
        struct Marker: Decodable {}
        let sessionStartedAt: Date
        let markers: [Marker]
    }

    /// Nil when the file is missing or cannot be decoded.
    public static func read(from folder: URL) -> MeetingMarkersSummary? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("markers.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data) else { return nil }
        return MeetingMarkersSummary(sessionStartedAt: file.sessionStartedAt, markerCount: file.markers.count)
    }
}
