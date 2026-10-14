import Foundation
import Testing
@testable import Roger

struct LibraryDocumentTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private var entry: LogEntry {
        LogEntry(text: "Called the supplier about the delayed shipment", startedAt: date,
                 endedAt: date.addingTimeInterval(33), presetName: "Log", language: nil)
    }

    private func writeLog(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("entry.md")
        try LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Rename

    @Test func renameChangesOnlyTitleAndHeading() throws {
        let text = LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date)
        let heading = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("# ") })
        let renamed = try #require(LibraryDocumentEditor.renamed(text, to: "Supplier call"))
        let expected = text
            .replacingOccurrences(of: "title: \(TranscriptFrontmatter.quoted(LogEntryWriter.title(for: entry)))\n", with: "title: \"Supplier call\"\n")
            .replacingOccurrences(of: heading + "\n", with: "# Supplier call\n")
        #expect(renamed == expected)
    }

    @Test func renameQuotesAndFlattensTheTitle() throws {
        let text = "---\ntype: source\ntitle: \"Old\"\n---\n\n# Old\n\nBody\n"
        let renamed = try #require(LibraryDocumentEditor.renamed(text, to: "  A \"quoted\": title\nwith a break "))
        #expect(renamed == "---\ntype: source\ntitle: \"A \\\"quoted\\\": title with a break\"\n---\n\n# A \"quoted\": title with a break\n\nBody\n")
    }

    @Test func renameAddsAMissingTitleAfterType() throws {
        let text = "---\ntype: source\ntags: [log]\n---\n\nNo heading here\n"
        #expect(LibraryDocumentEditor.renamed(text, to: "New") == "---\ntype: source\ntitle: \"New\"\ntags: [log]\n---\n\nNo heading here\n")
    }

    @Test func renameWithoutFrontmatterChangesTheHeadingOnly() {
        #expect(LibraryDocumentEditor.renamed("# Old\n\nBody\n", to: "New") == "# New\n\nBody\n")
    }

    @Test func renameNeedsATitleOrHeading() {
        #expect(LibraryDocumentEditor.renamed("Just text\n", to: "New") == nil)
        #expect(LibraryDocumentEditor.renamed("# Old\n", to: "   ") == nil)
    }

    @Test func renameFileKeepsFileName() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        try LibraryDocumentEditor.rename(fileAt: url, to: "Supplier call")
        #expect(try read(url).contains("title: \"Supplier call\"\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["entry.md"])
    }

    @Test func renameSkipsHeadingsInsideCodeFences() {
        let text = "---\ntitle: \"Old\"\n---\n\n```\n# comment\n```\n\n# Old\n"
        #expect(LibraryDocumentEditor.renamed(text, to: "New") == "---\ntitle: \"New\"\n---\n\n```\n# comment\n```\n\n# New\n")
    }

    /// A file from another editor: after a rename it is UTF-8 with LF, the
    /// title and the H1 changed, and every other line is still there.
    @Test(arguments: TextSample.allCases)
    func renameOfEveryVariantWritesUTF8WithLF(_ sample: TextSample) throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("note.md"))
        try LibraryDocumentEditor.rename(fileAt: url, to: "Neuer Titel")
        let expected = TextSample.text
            .replacingOccurrences(of: "title: \"\(TextSample.title)\"", with: "title: \"Neuer Titel\"")
            .replacingOccurrences(of: "# \(TextSample.title)", with: "# Neuer Titel")
        #expect(try Data(contentsOf: url) == Data(expected.utf8))
    }

    @Test(arguments: TextSample.allCases)
    func saveOfEveryVariantKeepsTheFrontmatter(_ sample: TextSample) throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("note.md"))
        let document = try LibraryDocument.load(url)
        #expect(document.frontmatter + document.body == TextSample.text)
        #expect(document.frontmatter.contains("title: \"\(TextSample.title)\"\n"))
        #expect(try LibraryDocumentEditor.saveBody("# Neu\r\n\r\nGeändert\r\n", of: document) == .saved)
        #expect(try Data(contentsOf: url) == Data((document.frontmatter + "# Neu\n\nGeändert\n").utf8))
    }

    @Test func renameNeedsNoCarriageReturnHandling() {
        // Text reaching `renamed` is already normalized by TextFile.
        #expect(LibraryDocumentEditor.renamed("# Old\nBody\n", to: "New") == "# New\nBody\n")
    }

    // MARK: Save

    @Test func saveKeepsExtendedAttributes() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let name = "com.apple.metadata:_kMDItemUserTags"
        let value = Array("tag".utf8)
        #expect(setxattr(url.path, name, value, value.count, 0, 0) == 0)
        _ = try LibraryDocumentEditor.saveBody("\nNew\n", of: try LibraryDocument.load(url))
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
        #expect(size == value.count)
        #expect(Array(buffer.prefix(max(size, 0))) == value)
    }

    @Test func saveReplacesOnlyTheBody() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        #expect(document.frontmatter + document.body == (try read(url)))

        let outcome = try LibraryDocumentEditor.saveBody("\n# Log\n\nFixed a typo\n", of: document)
        #expect(outcome == .saved)
        #expect(try read(url) == document.frontmatter + "\n# Log\n\nFixed a typo\n")
    }

    @Test func saveKeepsTheCreationDate() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        _ = try LibraryDocumentEditor.saveBody("\nNew\n", of: try LibraryDocument.load(url))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        #expect(after == created)
    }

    @Test func fileChangedOnDiskIsNotOverwrittenSilently() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        let otherEdit = try read(url) + "Added by another app\n"
        try otherEdit.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(600)], ofItemAtPath: url.path)

        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .changedOnDisk)
        #expect(try read(url) == otherEdit)
    }

    @Test func overwriteKeepsARenameMadeMeanwhile() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        try LibraryDocumentEditor.rename(fileAt: url, to: "Renamed meanwhile")
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(600)], ofItemAtPath: url.path)

        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .changedOnDisk)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document, overwrite: true) == .saved)
        let text = try read(url)
        #expect(text.contains("title: \"Renamed meanwhile\"\n"))
        #expect(text.hasSuffix("---\n\nMine\n"))
    }

    @Test func deletedFileIsNotRecreated() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        try FileManager.default.removeItem(at: url)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document, overwrite: true) == .missing)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Editable

    @Test func activeSessionAndUnfinishedMeetingsAreNotEditable() {
        let session = "/RogerFixtures/Meetings/2026/10/2026-10-13 09-00"
        let meeting = LibraryFixtures.item("transcript", kind: .meeting, folder: session)
        let log = LibraryFixtures.item("log")
        var unfinished = LibraryFixtures.item("x", kind: .meeting, folder: session, unfinished: true)
        unfinished.url = URL(fileURLWithPath: session, isDirectory: true)
        let active = URL(fileURLWithPath: session, isDirectory: true)

        #expect(!LibraryDocumentEditor.canEdit(meeting, activeSessionFolder: active))
        #expect(LibraryDocumentEditor.canEdit(meeting, activeSessionFolder: nil))
        #expect(LibraryDocumentEditor.canEdit(log, activeSessionFolder: active))
        #expect(!LibraryDocumentEditor.canEdit(unfinished, activeSessionFolder: nil))
    }

    // MARK: Symlinks

    /// `<folder>/note.md` is a link to `<folder>/real/note.md`.
    private func linkedLog(in folder: URL) throws -> (link: URL, target: URL) {
        let real = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = try writeLog(in: real)
        let link = folder.appendingPathComponent("note.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return (link, target)
    }

    private func isLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    @Test func saveWritesThroughASymlink() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        let document = try LibraryDocument.load(link)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .saved)
        #expect(try isLink(link))
        #expect(try read(target) == document.frontmatter + "\nMine\n")
    }

    @Test func renameWritesThroughASymlink() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        try LibraryDocumentEditor.rename(fileAt: link, to: "Through the link")
        #expect(try isLink(link))
        #expect(try read(target).contains("title: \"Through the link\"\n"))
    }

    /// Another app edits the file the link points to: the save must notice.
    @Test func targetChangedBehindALinkIsDetected() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        let document = try LibraryDocument.load(link)
        let otherEdit = try read(target) + "Added by another app\n"
        try otherEdit.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(600)], ofItemAtPath: target.path)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .changedOnDisk)
        #expect(try read(target) == otherEdit)
    }

    /// A link whose file is gone stays a link: nothing is written.
    @Test func aDanglingLinkIsNotReplaced() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        try FileManager.default.removeItem(at: target)
        #expect(throws: LibraryDocumentEditor.WriteError.linkTargetMissing) {
            try LibraryDocumentEditor.write("Text\n", to: link)
        }
        #expect(try isLink(link))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
