import Foundation
import Testing
@testable import Roger

struct LibraryItemReaderTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func logEntry() -> LogEntry {
        LogEntry(
            text: "Called the supplier about the delayed shipment",
            startedAt: date,
            endedAt: date.addingTimeInterval(33),
            presetName: "Log",
            language: "de"
        )
    }

    private func metadata(_ folder: URL) -> MeetingTranscriptWriter.Metadata {
        MeetingTranscriptWriter.Metadata(
            session: MeetingSession(id: UUID(), folder: folder, startedAt: date),
            durationSeconds: 120,
            speakerCount: 2,
            language: "en",
            micPresent: true,
            systemPresent: true,
            audioKept: true,
            diarized: false,
            diarizationFailed: false
        )
    }

    @Test func logEntryItem() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("2026-10-13 14-32-05.md")
        let audio = root.appendingPathComponent("2026-10-13 14-32-05.m4a")
        try LogEntryWriter.content(for: logEntry(), audioFileName: audio.lastPathComponent, generatedAt: date)
            .write(to: md, atomically: true, encoding: .utf8)
        try Data().write(to: audio)

        let item = try #require(LibraryItemReader.item(markdownAt: md, fallbackKind: .transcript))
        #expect(item.kind == .log)
        #expect(item.title == LogEntryWriter.title(for: logEntry()))
        #expect(item.date == date)
        #expect(item.durationSeconds == 33)
        #expect(item.preset == "Log")
        #expect(item.language == "de")
        #expect(item.audioFiles.map(\.lastPathComponent) == [audio.lastPathComponent])
        #expect(item.firstLine == "Called the supplier about the delayed shipment")
        #expect(item.searchText.contains("supplier"))
        #expect(item.folderURL == root)
        #expect(item.hasMarkdown)
        #expect(!item.isUnfinished)
    }

    @Test func audioIsListedOnlyWhenTheFileExists() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("a.md")
        try LogEntryWriter.content(for: logEntry(), audioFileName: "a.m4a", generatedAt: date)
            .write(to: md, atomically: true, encoding: .utf8)
        #expect(LibraryItemReader.item(markdownAt: md, fallbackKind: .log)?.hasAudio == false)
    }

    @Test func segmentFilesAreNotItems() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let url = try #require(try MeetingSegmentWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: "Hello")],
            sessionStartedAt: date,
            chunkStart: date,
            chunkEnd: date.addingTimeInterval(60),
            folder: root,
            provisional: false
        ))
        #expect(LibraryItemReader.item(markdownAt: url, fallbackKind: .meeting) == nil)
    }

    @Test func meetingItemFromSessionFolder() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        _ = try MeetingTranscriptWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: "Welcome everyone")],
            metadata: metadata(root)
        )
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: root))
        #expect(item.kind == .meeting)
        #expect(item.url.lastPathComponent == "transcript.md")
        #expect(item.folderURL == root)
        #expect(item.speakerCount == 2)
        #expect(item.durationSeconds == 120)
        #expect(item.title.hasPrefix("Meeting "))
        #expect(item.firstLine == "Welcome everyone")
        #expect(!item.isUnfinished)
    }

    @Test func unfinishedSessionWithoutTranscript() throws {
        let parent = try TempFolder.make()
        defer { TempFolder.remove(parent) }
        let folder = parent.appendingPathComponent("2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("mic-001.caf"))

        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.isUnfinished)
        #expect(item.url == folder)
        #expect(!item.hasMarkdown)
        #expect(item.date == LibraryMigration.sessionDate(for: folder))
        #expect(item.title == "Unfinished meeting 2026-10-13 09:00")
    }

    @Test func sessionWithoutAudioOrTranscriptIsNoItem() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("markers.json"))
        #expect(LibraryItemReader.meetingItem(sessionFolder: folder) == nil)
    }

    @Test func brokenFileFallsBackToFileNameAndDates() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("notes.md")
        try Data("---\ntitle: \"unclosed\nstill no end".utf8).write(to: md)
        let item = try #require(LibraryItemReader.item(markdownAt: md, fallbackKind: .transcript))
        #expect(item.kind == .transcript)
        #expect(item.title == "notes")
        #expect(item.date != .distantPast)
    }

    @Test func unreadableTextStillGivesAnItem() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("binary.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: md)
        let item = try #require(LibraryItemReader.item(markdownAt: md, fallbackKind: .log))
        #expect(item.title == "binary")
        #expect(item.kind == .log)
    }

    @Test func firstLineSkipsHeadingsImagesAndSpeakerHeaders() {
        let body = "\n# Meeting\n\n![Screenshot](a.png)\n\n**Me** [00:00:01 · 2026-10-13 09:00:01]\nHello **there**\n"
        #expect(LibraryItemReader.firstLine(ofBody: body) == "Hello there")
    }
}
