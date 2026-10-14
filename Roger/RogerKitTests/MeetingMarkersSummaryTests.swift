import Foundation
import Testing
@testable import RogerKit

struct MeetingMarkersSummaryTests {
    @Test func readsStartAndCount() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        // The shape MeetingCheckpointStore writes (ISO 8601 dates, sorted keys).
        let json = """
        {
          "markers" : [
            { "capturedAt" : "2026-10-13T07:05:00Z", "id" : "6F1C4A43-2B8C-4C55-9C1E-1F6D2A7B3C11", "imageFile" : "a.png", "offsetSeconds" : 300, "stemDate" : "2026-10-13T07:05:00Z" },
            { "capturedAt" : "2026-10-13T07:10:00Z", "id" : "7A2D5B54-3C9D-4D66-8D2F-2E7E3B8C4D22", "imageFile" : "b.png", "offsetSeconds" : 600, "stemDate" : "2026-10-13T07:10:00Z" }
          ],
          "sessionStartedAt" : "2026-10-13T07:00:00Z",
          "version" : 1
        }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("markers.json"))
        let summary = try #require(MeetingMarkersSummary.read(from: folder))
        #expect(summary.markerCount == 2)
        #expect(summary.sessionStartedAt == ISO8601DateFormatter().date(from: "2026-10-13T07:00:00Z"))
    }

    @Test func missingOrBrokenFileIsNil() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        #expect(MeetingMarkersSummary.read(from: folder) == nil)
        try Data("{ nope".utf8).write(to: folder.appendingPathComponent("markers.json"))
        #expect(MeetingMarkersSummary.read(from: folder) == nil)
    }
}
