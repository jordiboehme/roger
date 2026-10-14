import Foundation
import Testing
@testable import Roger

struct MeetingSegmentWriterTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func write(_ folder: URL, _ text: String, provisional: Bool, generatedAt: Date = .now) throws -> URL {
        try #require(try MeetingSegmentWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: text)],
            sessionStartedAt: start,
            chunkStart: start,
            chunkEnd: start.addingTimeInterval(30),
            folder: folder,
            provisional: provisional,
            generatedAt: generatedAt
        ))
    }

    private func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func previous(_ url: URL, _ suffix: String = "") -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".previous\(suffix).md")
    }

    @Test func draftIsReplaced() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Live words", provisional: true)
        _ = try write(folder, "Final words", provisional: false)
        #expect(try names(folder) == [url.lastPathComponent])
        let text = try read(url)
        #expect(text.contains("Final words"))
        #expect(text.contains("\nstatus: stable\n"))
    }

    @Test func stableSegmentIsMovedAsideBeforeARetry() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false)
        try (try read(url) + "My own note\n").write(to: url, atomically: true, encoding: .utf8)
        _ = try write(folder, "Retry words", provisional: false)
        #expect(try read(previous(url)).contains("My own note"))
        #expect(try read(url).contains("Retry words"))
    }

    @Test func anExistingPreviousFileIsNeverOverwritten() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false)
        try "older copy".write(to: previous(url), atomically: true, encoding: .utf8)
        try (try read(url) + "My own note\n").write(to: url, atomically: true, encoding: .utf8)
        _ = try write(folder, "Retry words", provisional: false)
        #expect(try read(previous(url)) == "older copy")
        #expect(try read(previous(url, " 1")).contains("My own note"))
    }

    @Test func aHandWrittenFileWithoutFrontmatterIsKept() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = folder.appendingPathComponent(MeetingSegmentWriter.fileName(chunkStart: start))
        try "my notes".write(to: url, atomically: true, encoding: .utf8)
        _ = try write(folder, "Retry words", provisional: false)
        #expect(try read(previous(url)) == "my notes")
    }

    @Test func anEmptyRangeKeepsAStableSegment() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false)
        MeetingSegmentWriter.removeIfExists(chunkStart: start, folder: folder)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try read(previous(url)).contains("Final words"))
    }

    @Test func anEmptyRangeDropsADraft() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        _ = try write(folder, "Live words", provisional: true)
        MeetingSegmentWriter.removeIfExists(chunkStart: start, folder: folder)
        #expect(try names(folder).isEmpty)
    }

    /// A retry with the same text (written days later) leaves no `.previous` copy.
    @Test func anUnchangedStableSegmentIsNotMovedAside() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false, generatedAt: start)
        let first = try read(url)
        _ = try write(folder, "Final words", provisional: false, generatedAt: start.addingTimeInterval(3 * 86_400))
        #expect(try names(folder) == [url.lastPathComponent])
        #expect(try read(url) == first)
    }

    @Test func aChangedStableSegmentIsStillMovedAside() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false, generatedAt: start)
        _ = try write(folder, "Other words", provisional: false, generatedAt: start.addingTimeInterval(3 * 86_400))
        #expect(try read(previous(url)).contains("Final words"))
        #expect(try read(url).contains("Other words"))
    }

    /// A retry over a segment another editor saved with CRLF, unchanged
    /// otherwise: the file stays and no `.previous` copy is made.
    @Test func anUnchangedCRLFSegmentCountsAsUnchanged() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false, generatedAt: start)
        let crlf = try read(url).replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlf.utf8).write(to: url)
        _ = try write(folder, "Final words", provisional: false, generatedAt: start.addingTimeInterval(3 * 86_400))
        #expect(try names(folder) == [url.lastPathComponent])
        #expect(try Data(contentsOf: url) == Data(crlf.utf8))
    }

    @Test func aCRLFDraftIsStillADraft() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Live words", provisional: true)
        try Data(try read(url).replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: url)
        #expect(MeetingSegmentWriter.isDraft(url))
    }
}
