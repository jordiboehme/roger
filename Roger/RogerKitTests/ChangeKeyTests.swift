import CryptoKit
import Foundation
import Testing
@testable import RogerKit

struct ChangeKeyTests {
    private let date = KitFixtures.base

    private func hash8(_ path: String) -> String {
        String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    @Test func logKeyIsTheRelativePathWithoutMd() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let md = try KitFixtures.log(in: LibraryLayout(root: root), at: date, text: "x")
        let subject = ChangeKey.subject(markdownURL: md, kind: .log, root: root)
        let month = LibraryLayout(root: root).monthFolder(.logs, for: date)
        let relativeMonth = LibraryPath.components(of: LibraryPath.canonical(month), below: LibraryPath.canonical(root)).joined(separator: "/")
        #expect(subject.key == relativeMonth + "/" + KitFixtures.stem(date))
        #expect(subject.path == relativeMonth + "/" + KitFixtures.stem(date) + ".md")
        #expect(!subject.isExternal)
    }

    @Test func meetingKeyIsTheSessionFolder() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let session = try KitFixtures.meeting(in: root.appendingPathComponent("Meetings/2026/10"), name: "2026-10-13 09-00", at: date, text: "x")
        let subject = ChangeKey.subject(markdownURL: session.appendingPathComponent("transcript.md"), kind: .meeting, root: root)
        #expect(subject == ChangeSubject(kind: .meeting, key: "Meetings/2026/10/2026-10-13 09-00", path: "Meetings/2026/10/2026-10-13 09-00/transcript.md"))
    }

    @Test func doubleExtensionKeepsTheMediaExtension() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let md = try KitFixtures.transcript(at: root.appendingPathComponent("Transcripts/2026/10/talk.mp4.md"), at: date, title: "Talk", text: "x")
        #expect(ChangeKey.subject(markdownURL: md, kind: .transcript, root: root).key == "Transcripts/2026/10/talk.mp4")
    }

    @Test func fileOutsideTheRootIsExternal() throws {
        let home = try TempDir.make()
        defer { TempDir.remove(home) }
        let root = home.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let md = try KitFixtures.transcript(at: home.appendingPathComponent("Media/clip.m4a.md"), at: date, title: "Clip", text: "x")
        let canonical = LibraryPath.canonical(md)
        let subject = ChangeKey.subject(markdownURL: md, kind: .transcript, root: root)
        #expect(subject.key == "External/clip.m4a-" + hash8(canonical))
        #expect(subject.path == canonical)
        #expect(subject.isExternal)
    }

    @Test func meetingOutsideTheRootHashesTheFolder() throws {
        let home = try TempDir.make()
        defer { TempDir.remove(home) }
        let session = try KitFixtures.meeting(in: home.appendingPathComponent("Roger Recordings"), name: "2025-01-02 10-00", at: date, text: "x")
        let subject = ChangeKey.subject(markdownURL: session.appendingPathComponent("transcript.md"), kind: .meeting, root: home.appendingPathComponent("Library"))
        #expect(subject.key == "External/2025-01-02 10-00-" + hash8(LibraryPath.canonical(session)))
        #expect(subject.path == LibraryPath.canonical(session.appendingPathComponent("transcript.md")))
    }

    @Test func bothSpellingsOfTheRootGiveOneKey() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let md = try KitFixtures.log(in: LibraryLayout(root: root), at: date, text: "x")
        let real = URL(fileURLWithPath: LibraryPath.canonical(root), isDirectory: true)
        #expect(ChangeKey.subject(markdownURL: md, kind: .log, root: root) == ChangeKey.subject(markdownURL: md, kind: .log, root: real))
    }

    @Test func unfinishedMeetingHasNoSubject() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let session = root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data().write(to: session.appendingPathComponent("mic-001.caf"))
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: session))
        #expect(ChangeKey.subject(for: item, root: root) == nil)
    }
}
