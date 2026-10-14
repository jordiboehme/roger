import Foundation
import Testing
@testable import RogerKit

struct ChangeQueryTests {
    private let base = KitFixtures.base

    private func event(_ seq: Int, _ type: ChangeEventType, _ subject: ChangeSubject, at: Date? = nil) -> ChangeEvent {
        ChangeEvent(seq: seq, at: at ?? base.addingTimeInterval(Double(seq)), event: type, kind: subject.kind, key: subject.key, path: subject.path)
    }

    private func log(_ root: URL, minute: Int, text: String) throws -> ChangeSubject {
        let md = try KitFixtures.log(in: LibraryLayout(root: root), at: base.addingTimeInterval(Double(minute) * 60), text: text)
        return ChangeKey.subject(markdownURL: md, kind: .log, root: root)
    }

    @Test func oneEntryPerKeyAtItsLatestSeq() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        let b = try log(root, minute: 1, text: "bravo")
        let events = [event(1, .created, a), event(2, .created, b), event(3, .updated, a)]
        let answer = ChangeQuery.run(events: events, start: .afterSeq(0), kinds: nil, summary: false, root: root)
        #expect(answer.entries.map(\.seq) == [2, 3])
        #expect(answer.entries.map(\.event) == [.created, .updated])
        #expect(answer.from == 1 && answer.upTo == 3 && !answer.more)
        #expect(answer.entries[1].markdown?.contains("alpha") == true)
        #expect(answer.entries[1].paths.first?.hasSuffix(KitFixtures.stem(base) + ".md") == true)
    }

    @Test func deletedEntryHasNoTextAndNoPaths() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        let answer = ChangeQuery.run(events: [event(1, .created, a), event(2, .deleted, a)], start: .afterSeq(0), kinds: nil, summary: false, root: root)
        let entry = try #require(answer.entries.first)
        #expect(entry.event == .deleted && entry.markdown == nil && entry.paths.isEmpty && entry.title == nil)
        #expect(!entry.render().contains("paths"))
    }

    @Test func missingFileIsMarked() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        try FileManager.default.removeItem(at: root.appendingPathComponent(a.path))
        let entry = try #require(ChangeQuery.run(events: [event(1, .created, a)], start: .afterSeq(0), kinds: nil, summary: false, root: root).entries.first)
        #expect(entry.missing && entry.markdown == nil && entry.paths.isEmpty)
        #expect(entry.render().contains("missing: true"))
    }

    @Test func cutsAtAnItemBoundary() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let text = String(repeating: "word ", count: 2_000)
        let subjects = try (0..<5).map { try log(root, minute: $0, text: text) }
        let events = subjects.enumerated().map { event($0.offset + 1, .created, $0.element) }
        let first = ChangeQuery.run(events: events, start: .afterSeq(0), kinds: nil, summary: false, root: root)
        #expect(first.entries.count == 2)
        #expect(first.more)
        #expect(first.upTo == 2)
        let second = ChangeQuery.run(events: events, start: .afterSeq(first.upTo), kinds: nil, summary: false, root: root)
        #expect(second.entries.map(\.seq) == [3, 4])
        let last = ChangeQuery.run(events: events, start: .afterSeq(second.upTo), kinds: nil, summary: false, root: root)
        #expect(last.entries.map(\.seq) == [5])
        #expect(!last.more && last.upTo == 5)
    }

    @Test func aSingleOversizedEntryComesWhole() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let big = try log(root, minute: 0, text: String(repeating: "x", count: 45_000))
        let small = try log(root, minute: 1, text: "small")
        let answer = ChangeQuery.run(events: [event(1, .created, big), event(2, .created, small)], start: .afterSeq(0), kinds: nil, summary: false, root: root)
        #expect(answer.entries.map(\.seq) == [1])
        #expect(answer.entries[0].markdown?.contains(String(repeating: "x", count: 45_000)) == true)
        #expect(answer.more && answer.upTo == 1)
    }

    @Test func kindsFilterKeepsTheRangeEnd() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        try KitFixtures.meeting(in: root.appendingPathComponent("Meetings/2026/10"), name: "2026-10-13 09-00", at: base, text: "hello")
        let meeting = ChangeKey.subject(markdownURL: root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00/transcript.md"), kind: .meeting, root: root)
        let answer = ChangeQuery.run(events: [event(1, .created, meeting), event(2, .created, a)], start: .afterSeq(0), kinds: [.meeting], summary: false, root: root)
        #expect(answer.entries.map(\.kind) == [.meeting])
        #expect(answer.upTo == 2)
    }

    @Test func summaryHasNoTextAndALargerLimit() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let text = String(repeating: "word ", count: 2_000)
        let subjects = try (0..<5).map { try log(root, minute: $0, text: text) }
        let events = subjects.enumerated().map { event($0.offset + 1, .created, $0.element) }
        let answer = ChangeQuery.run(events: events, start: .afterSeq(0), kinds: nil, summary: true, root: root)
        #expect(answer.entries.count == 5)
        #expect(answer.entries.allSatisfy { $0.markdown == nil && $0.title != nil })
        #expect(!answer.more)
    }

    /// Claude Code moves a tool answer over 50,000 characters into a file,
    /// so a summary stops at 45,000.
    @Test func summaryStaysBelowFiftyThousandCharacters() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let padding = String(repeating: "x", count: 150)
        let events = (1...1_000).map { seq in
            ChangeEvent(seq: seq, at: base.addingTimeInterval(Double(seq)), event: .deleted, kind: .log,
                        key: "Logs/2026/10/\(padding)-\(seq)", path: "Logs/2026/10/\(padding)-\(seq).md")
        }
        let answer = ChangeQuery.run(events: events, start: .afterSeq(0), kinds: nil, summary: true, root: root)
        #expect(ChangeQuery.summaryLimit == 45_000)
        #expect(answer.more)
        #expect(answer.render().count < 50_000)
        #expect(answer.render().count > 40_000)
    }

    @Test func upToDateConsumerGetsAnEmptyAnswer() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        let answer = ChangeQuery.run(events: [event(1, .created, a)], start: .afterSeq(1), kinds: nil, summary: false, root: root)
        #expect(answer.entries.isEmpty && answer.from == 2 && answer.upTo == 1 && !answer.more)
        #expect(answer.render() == "from: 2\nupTo: 1\nmore: false\ncount: 0")
    }

    @Test func sinceAboveTheLastSeqAnswersWithTheLastSeq() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let subjects = try (0..<3).map { try log(root, minute: $0, text: "n\($0)") }
        let events = subjects.enumerated().map { event($0.offset + 1, .created, $0.element) }
        let answer = ChangeQuery.run(events: events, start: .afterSeq(10), kinds: nil, summary: false, root: root)
        #expect(answer.entries.count == 0)
        #expect(answer.upTo == 3)
    }

    @Test func rangeFormIsFixed() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let subjects = try (0..<5).map { try log(root, minute: $0, text: "n\($0)") }
        let events = subjects.enumerated().map { event($0.offset + 1, .created, $0.element) }
        let answer = ChangeQuery.run(events: events, start: .range(from: 2, upTo: 3), kinds: nil, summary: false, root: root)
        #expect(answer.entries.map(\.seq) == [2, 3])
        #expect(answer.from == 2 && answer.upTo == 3)
    }

    @Test func timeStartUsesEventTimes() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        let b = try log(root, minute: 1, text: "bravo")
        let events = [event(1, .created, a, at: base), event(2, .created, b, at: base.addingTimeInterval(3_600))]
        let answer = ChangeQuery.run(events: events, start: .atOrAfter(base.addingTimeInterval(60)), kinds: nil, summary: false, root: root)
        #expect(answer.entries.map(\.seq) == [2])
        #expect(answer.from == 2)
    }

    @Test func renderedAnswerHasHeadThenEntries() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = try log(root, minute: 0, text: "alpha")
        let text = ChangeQuery.run(events: [event(1, .created, a)], start: .afterSeq(0), kinds: nil, summary: false, root: root).render()
        #expect(text.hasPrefix("from: 1\nupTo: 1\nmore: false\ncount: 1\n\n==== roger entry 1 ====\nseq: 1\nevent: created\nkind: log\nkey: "))
        #expect(text.contains("\npaths[1]: /"))
        #expect(text.contains("\n\n---\ntype: source"))
    }
}

struct SinceParserTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func seq() {
        #expect(SinceParser.parse("12", now: now) == .afterSeq(12))
        #expect(SinceParser.parse("0", now: now) == .afterSeq(0))
    }

    @Test func dayIsLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let expected = try #require(RFC3339.date("2026-10-13T00:00:00+02:00"))
        #expect(SinceParser.parse("2026-10-13", now: now, calendar: calendar) == .atOrAfter(expected))
    }

    @Test func rfc3339() throws {
        #expect(SinceParser.parse("2026-10-13T14:32:41+02:00", now: now) == .atOrAfter(try #require(RFC3339.date("2026-10-13T14:32:41+02:00"))))
    }

    @Test func durations() {
        #expect(SinceParser.parse("30m", now: now) == .atOrAfter(now.addingTimeInterval(-1_800)))
        #expect(SinceParser.parse("12h", now: now) == .atOrAfter(now.addingTimeInterval(-43_200)))
        #expect(SinceParser.parse("3d", now: now) == .atOrAfter(now.addingTimeInterval(-259_200)))
    }

    @Test(arguments: ["", "yesterday", "-1", "3w", "h", "2026-13-45", "12 h"])
    func rejects(raw: String) {
        #expect(SinceParser.parse(raw, now: now) == nil)
    }

    /// Guard test: the regex `$` was never reached with a newline (the text is
    /// trimmed or `DateFormatter` refuses it), so this passes before the change.
    @Test func aDayWithANewlineIsNoDay() {
        #expect(SinceParser.parse("2026-10-13\n", now: now) == nil)
        #expect(SinceParser.parse("2026-1-13", now: now) == nil)
    }
}
