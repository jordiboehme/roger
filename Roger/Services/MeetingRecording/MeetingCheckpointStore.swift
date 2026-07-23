import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingCheckpoints")

/// Filename stem format: the session-folder convention plus seconds.
/// Lexicographic order equals chronological order.
private let stemFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return f
}()

/// A screenshot checkpoint recorded while a meeting recording is live. The
/// marker splits the transcript into chronological segments: the segment
/// ending at this marker covers `[previous marker, this marker)`.
///
/// `stemDate` drives every filename derived from the marker. It starts as
/// `capturedAt` and is bumped forward in whole seconds until its filename stem
/// is unique within the session folder, so files always sort chronologically
/// and never collide.
struct MeetingCheckpointMarker: Codable, Sendable, Equatable {
    let id: UUID
    /// Wall-clock moment of the drop.
    let capturedAt: Date
    /// `capturedAt` relative to the session start. Authoritative for segment
    /// ranges — ISO8601 in markers.json drops sub-second precision, this
    /// Double keeps it.
    let offsetSeconds: Double
    /// `capturedAt`, bumped +1 s until the filename stem is unique.
    let stemDate: Date
    /// Screenshot filename inside the session folder, e.g.
    /// "2026-07-23 14-42-17.png".
    let imageFile: String
}

/// On-disk shape of `markers.json`. `sessionStartedAt` is persisted so crash
/// recovery reconstructs exact segment names and absolute timestamps — the
/// folder name only has minute precision.
struct MeetingCheckpointFile: Codable, Sendable {
    var version: Int
    var sessionStartedAt: Date
    var markers: [MeetingCheckpointMarker]
}

/// What a drop on the meeting overlay delivers after AppKit normalisation.
enum MeetingCheckpointImage: Sendable {
    /// An image file on disk — a Finder drag (`deleteAfterCopy: false`) or a
    /// received file promise in a temp folder (`deleteAfterCopy: true`).
    case file(URL, deleteAfterCopy: Bool)
    /// Raw pasteboard image bytes, already converted to PNG.
    case pngData(Data)
}

/// Owns the checkpoint markers of one live session: assigns collision-free
/// filename stems and rewrites `markers.json` atomically on every drop so
/// screenshots and their markers survive a crash.
@MainActor
final class MeetingCheckpointStore {
    private(set) var file: MeetingCheckpointFile
    let folder: URL

    init(folder: URL, sessionStartedAt: Date) {
        self.folder = folder
        self.file = MeetingCheckpointFile(version: 1, sessionStartedAt: sessionStartedAt, markers: [])
    }

    /// Formats a filename stem — nonisolated so `MeetingSegmentWriter` can
    /// derive segment filenames off the main actor.
    nonisolated static func stem(for date: Date) -> String {
        stemFormatter.string(from: date)
    }

    static func markersURL(in folder: URL) -> URL {
        folder.appendingPathComponent("markers.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Reads a session folder's markers.json. Nil when absent or corrupt —
    /// finalisation then behaves as if no screenshots were dropped.
    static func load(from folder: URL) -> MeetingCheckpointFile? {
        let url = markersURL(in: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(MeetingCheckpointFile.self, from: data)
        } catch {
            logger.error("Corrupt markers.json in \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Builds a marker for a drop at `capturedAt`, bumping `stemDate` until
    /// the stem collides with no prior marker and no existing file in the
    /// folder. Does not persist — call `append(_:)` once the screenshot is
    /// safely on disk.
    func makeMarker(capturedAt: Date, fileExtension: String) -> MeetingCheckpointMarker {
        var stemDate = capturedAt
        while stemCollides(Self.stem(for: stemDate)) {
            stemDate = stemDate.addingTimeInterval(1)
        }
        return MeetingCheckpointMarker(
            id: UUID(),
            capturedAt: capturedAt,
            offsetSeconds: capturedAt.timeIntervalSince(file.sessionStartedAt),
            stemDate: stemDate,
            imageFile: "\(Self.stem(for: stemDate)).\(fileExtension)"
        )
    }

    /// True when `stem` is already taken by a prior marker or any file in the
    /// session folder (prefix match, so "X.png" blocks stem "X" regardless of
    /// extension).
    private func stemCollides(_ stem: String) -> Bool {
        if file.markers.contains(where: { Self.stem(for: $0.stemDate) == stem }) {
            return true
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix(stem) }
    }

    /// Appends the marker (kept sorted by offset, so a file promise that
    /// resolves after a later direct drop still lands chronologically) and
    /// atomically rewrites markers.json.
    func append(_ marker: MeetingCheckpointMarker) throws {
        file.markers.append(marker)
        file.markers.sort { $0.offsetSeconds < $1.offsetSeconds }
        let data = try Self.encoder.encode(file)
        try data.write(to: Self.markersURL(in: folder), options: .atomic)
    }

    /// Where the segment ending at `marker` starts: the previous marker's
    /// stem +1 s, or the session start for the first marker. The +1 s keeps
    /// the segment md sorting after the screenshot that opens it (identical
    /// stems would sort ".md" before ".png").
    func chunkContext(for marker: MeetingCheckpointMarker) -> (chunkStart: Date, previousOffset: Double) {
        let previous = file.markers
            .filter { $0.id != marker.id && $0.offsetSeconds <= marker.offsetSeconds }
            .max { $0.offsetSeconds < $1.offsetSeconds }
        guard let previous else {
            return (file.sessionStartedAt, 0)
        }
        return (previous.stemDate.addingTimeInterval(1), previous.offsetSeconds)
    }

    /// All segment boundaries for finalisation: each segment's start date
    /// (drives its filename) paired with its half-open paragraph-offset
    /// range. The trailing segment runs to infinity. Empty markers → empty.
    static func chunks(
        sessionStartedAt: Date,
        markers: [MeetingCheckpointMarker]
    ) -> [(start: Date, range: Range<Double>)] {
        guard !markers.isEmpty else { return [] }
        let sorted = markers.sorted { $0.offsetSeconds < $1.offsetSeconds }
        var result: [(start: Date, range: Range<Double>)] = []
        var previousStart = sessionStartedAt
        var previousOffset = 0.0
        for marker in sorted {
            result.append((start: previousStart, range: previousOffset..<max(previousOffset, marker.offsetSeconds)))
            previousStart = marker.stemDate.addingTimeInterval(1)
            previousOffset = max(previousOffset, marker.offsetSeconds)
        }
        result.append((start: previousStart, range: previousOffset..<Double.infinity))
        return result
    }
}
