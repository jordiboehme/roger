import Foundation
import SwiftUI
import Testing
@testable import Roger

struct LibraryMarkdownTests {
    private let base = URL(fileURLWithPath: "/RogerFixtures/Meetings/2026/10/s", isDirectory: true)

    @Test func headingsParagraphsAndImages() {
        let body = "\n# Meeting\n\n**Me** [00:00:01]\nHello there\n\n![Screenshot at 00:01:00](2026-10-13%2009-01-00.png)\n\n## Notes\nLine one\nLine two\n"
        #expect(LibraryMarkdown.blocks(from: body, baseURL: base) == [
            .heading(level: 1, text: "Meeting"),
            .paragraph("**Me** [00:00:01]\nHello there"),
            .image(alt: "Screenshot at 00:01:00", url: base.appendingPathComponent("2026-10-13 09-01-00.png").standardizedFileURL),
            .heading(level: 2, text: "Notes"),
            .paragraph("Line one\nLine two"),
        ])
    }

    @Test func remoteImagesAndHashtagsStayText() {
        let body = "![logo](https://example.com/a.png)\n\n#hashtag is not a heading\n"
        #expect(LibraryMarkdown.blocks(from: body, baseURL: base) == [
            .paragraph("![logo](https://example.com/a.png)"),
            .paragraph("#hashtag is not a heading"),
        ])
    }

    @Test func meetingScreenshotsResolveToTheSessionFolder() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let marker = MeetingCheckpointMarker(
            id: UUID(), capturedAt: start.addingTimeInterval(5), offsetSeconds: 5,
            stemDate: start.addingTimeInterval(5), imageFile: "2026-09-21 16-13-25.png"
        )
        let url = try MeetingTranscriptWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 10, text: "After the slide")],
            metadata: .init(session: MeetingSession(id: UUID(), folder: folder, startedAt: start),
                            durationSeconds: 60, speakerCount: 1, language: nil, micPresent: true,
                            systemPresent: false, audioKept: true, diarized: false, diarizationFailed: false),
            markers: [marker]
        )
        let document = try LibraryDocument.load(url)
        let images = LibraryMarkdown.blocks(from: document.body, baseURL: folder).compactMap { block -> URL? in
            if case .image(_, let url) = block { return url }
            return nil
        }
        #expect(images == [folder.appendingPathComponent("2026-09-21 16-13-25.png").standardizedFileURL])
    }

    /// A click on a preview image opens it, so only image files inside the
    /// item's folder may become images. Everything else stays text.
    @Test func imagesOutsideTheItemFolderStayText() {
        let lines = [
            "![x](/tmp/a.png)",
            "![x](/Applications/Calculator.app)",
            "![x](../../run.command)",
            "![x](../a.png)",
            "![x](shots/../../a.png)",
            "![x](%2E%2E/a.png)",
            "![x](file:///tmp/a.png)",
            "![x](http://example.com/a.png)",
            "![x](mailto:a.png)",
            "![x](notes.md)",
        ]
        for line in lines {
            #expect(LibraryMarkdown.blocks(from: line, baseURL: base) == [.paragraph(line)], "\(line)")
        }
    }

    @Test func relativeImageInsideTheFolderIsAnImage() {
        #expect(LibraryMarkdown.blocks(from: "![Shot](shots/a%20b.PNG)", baseURL: base) == [
            .image(alt: "Shot", url: base.appendingPathComponent("shots/a b.PNG").standardizedFileURL),
        ])
    }

    @Test func symlinkOutOfTheFolderStaysText() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let folder = root.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.png"), withDestinationURL: outside
        )
        #expect(LibraryMarkdown.blocks(from: "![x](link.png)", baseURL: folder) == [.paragraph("![x](link.png)")])
    }

    /// Only web links stay clickable; `file:` and app schemes become text.
    @Test func onlyWebLinksStayClickable() {
        let result = LibraryMarkdown.attributed(
            "[web](https://example.com) [file](file:///Applications/Calculator.app) [app](x-apple.systempreferences:a) [plain](http://example.org)",
            highlighting: []
        )
        #expect(result.runs.compactMap(\.link) == [URL(string: "https://example.com")!, URL(string: "http://example.org")!])
        #expect(String(result.characters) == "web file app plain")
    }

    @Test func highlightRangesIgnoreCase() {
        let text = "Supplier called. The supplier said yes."
        let found = LibraryMarkdown.highlightRanges(of: ["supplier"], in: text).map { String(text[$0]) }
        #expect(found == ["Supplier", "supplier"])
        #expect(LibraryMarkdown.highlightRanges(of: [], in: text).isEmpty)
    }

    @Test func attributedHighlightsTheMatchesOnly() {
        let result = LibraryMarkdown.attributed("Call the **supplier** now", highlighting: ["supplier"])
        #expect(String(result.characters) == "Call the supplier now")
        let marked = result.runs
            .filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }
            .map { String(result[$0.range].characters) }
            .joined()
        #expect(marked == "supplier")
    }
}
