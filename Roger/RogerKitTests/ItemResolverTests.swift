import Foundation
import Testing
@testable import RogerKit

struct ItemResolverTests {
    private let date = KitFixtures.base

    @Test(arguments: ["", "../x", "Logs/../../etc/passwd", "/etc/passwd", "~/x", "Logs//x", "Logs/./x", ".roger/changes", "Logs/.hidden", "Logs\\x"])
    func rejectsKeysThatLeaveTheLibrary(key: String) throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        #expect(throws: ItemKeyError.invalid(key)) {
            try ItemResolver.subject(forKey: key, root: root, events: [])
        }
    }

    @Test func resolvesLogAndMeetingKeys() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        let md = try KitFixtures.log(in: layout, at: date, text: "x")
        let session = try KitFixtures.meeting(in: root.appendingPathComponent("Meetings/2026/10"), name: "2026-10-13 09-00", at: date, text: "x")
        let logKey = ChangeKey.subject(markdownURL: md, kind: .log, root: root).key
        #expect(try ItemResolver.subject(forKey: logKey, root: root, events: []).kind == .log)
        let meeting = try ItemResolver.subject(forKey: "Meetings/2026/10/2026-10-13 09-00", root: root, events: [])
        #expect(meeting.kind == .meeting)
        #expect(meeting.path == "Meetings/2026/10/2026-10-13 09-00/transcript.md")
        #expect(FileManager.default.fileExists(atPath: session.path))
    }

    @Test func unknownKeyIsNotFound() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        #expect(throws: ItemKeyError.notFound("Logs/2026/10/nothing")) {
            try ItemResolver.subject(forKey: "Logs/2026/10/nothing", root: root, events: [])
        }
    }

    @Test func externalKeysComeOnlyFromTheLog() throws {
        let home = try TempDir.make()
        defer { TempDir.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        let md = try KitFixtures.transcript(at: home.appendingPathComponent("Media/clip.m4a.md"), at: date, title: "Clip", text: "x")
        let subject = ChangeKey.subject(markdownURL: md, kind: .transcript, root: root)
        #expect(throws: ItemKeyError.notFound(subject.key)) {
            try ItemResolver.subject(forKey: subject.key, root: root, events: [])
        }
        let created = ChangeEvent(seq: 1, at: date, event: .created, kind: .transcript, key: subject.key, path: subject.path)
        #expect(try ItemResolver.subject(forKey: subject.key, root: root, events: [created]) == subject)
        let deleted = ChangeEvent(seq: 2, at: date, event: .deleted, kind: .transcript, key: subject.key, path: subject.path)
        #expect(throws: ItemKeyError.notFound(subject.key)) {
            try ItemResolver.subject(forKey: subject.key, root: root, events: [created, deleted])
        }
    }

    @Test func symlinkOutOfTheLibraryIsRejected() throws {
        let home = try TempDir.make()
        defer { TempDir.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        let outside = try KitFixtures.transcript(at: home.appendingPathComponent("secret.md"), at: date, title: "Secret", text: "x")
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("link.md"), withDestinationURL: outside)
        #expect(throws: ItemKeyError.invalid("Logs/link")) {
            try ItemResolver.subject(forKey: "Logs/link", root: root, events: [])
        }
    }

    @Test func pathsListMarkdownAudioAndScreenshots() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let session = try KitFixtures.meeting(in: root.appendingPathComponent("Meetings/2026/10"), name: "2026-10-13 09-00", at: date, text: "x", screenshot: true)
        let item = try #require(ItemResolver.item(path: "Meetings/2026/10/2026-10-13 09-00/transcript.md", kind: .meeting, root: root))
        let names = ItemResolver.paths(of: item).map { ($0 as NSString).lastPathComponent }
        #expect(names == ["transcript.md", "mic.m4a", KitFixtures.stem(date) + ".png"])
        #expect(ItemResolver.paths(of: item).allSatisfy { $0.hasPrefix("/") })
        #expect(item.folderURL.lastPathComponent == session.lastPathComponent)
    }

    @Test func missingFileGivesNoItem() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        #expect(ItemResolver.item(path: "Logs/2026/10/gone.md", kind: .log, root: root) == nil)
    }
}
