import Foundation
import Testing
@testable import RogerKit

struct ChangeLogTests {
    private func change(_ n: Int, _ event: ChangeEventType = .created) -> PendingChange {
        PendingChange(event: event, kind: .log, key: "Logs/2026/10/entry \(n)", path: "Logs/2026/10/entry \(n).md")
    }

    @Test func lineHasTheSpecFieldOrder() throws {
        let at = try #require(RFC3339.date("2026-10-13T14:32:41+02:00"))
        let event = ChangeEvent(
            seq: 42, at: at, event: .created, kind: .log,
            key: "Logs/2026/10/2026-10-13 14-32-05", path: "Logs/2026/10/2026-10-13 14-32-05.md"
        )
        let line = event.jsonLine(timeZone: try #require(TimeZone(secondsFromGMT: 7200)))
        #expect(line == #"{"seq":42,"at":"2026-10-13T14:32:41+02:00","event":"created","kind":"log","key":"Logs/2026/10/2026-10-13 14-32-05","path":"Logs/2026/10/2026-10-13 14-32-05.md"}"#)
        #expect(ChangeEvent.parse(Data(line.utf8)) == event)
    }

    @Test func keysWithQuotesAndBackslashesRoundTrip() throws {
        let event = ChangeEvent(seq: 1, at: Date(timeIntervalSince1970: 1_790_000_000), event: .updated, kind: .transcript,
                                key: "External/a \"b\" \\ c-0123abcd", path: "/tmp/a \"b\" \\ c.md")
        #expect(ChangeEvent.parse(Data(event.jsonLine().utf8)) == event)
    }

    @Test func seqStartsAtOneAndIncreases() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let log = ChangeLog(root: root)
        let first = try await log.append([change(1)])
        let next = try await log.append([change(2), change(3)])
        #expect(first.map(\.seq) == [1])
        #expect(next.map(\.seq) == [2, 3])
        #expect(try ChangeLogFile.readEvents(root: root).map(\.seq) == [1, 2, 3])
        #expect(log.fileURL.path.hasSuffix("/.roger/changes.jsonl"))
    }

    @Test func ensureFileCreatesAnEmptyLog() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        try await ChangeLog(root: root).ensureFile()
        #expect(try Data(contentsOf: ChangeLogFile.url(root: root)).isEmpty)
        #expect(try ChangeLogFile.readEvents(root: root).isEmpty)
    }

    @Test func twoHandlesNeverShareASeq() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let a = ChangeLog(root: root)
        let b = ChangeLog(root: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<100 {
                let log = n.isMultiple(of: 2) ? a : b
                group.addTask { _ = try await log.append([PendingChange(event: .created, kind: .log, key: "k\(n)", path: "k\(n).md")]) }
            }
            try await group.waitForAll()
        }
        let events = try ChangeLogFile.readEvents(root: root)
        #expect(events.map(\.seq).sorted() == Array(1...100))
        #expect(Set(events.map(\.key)).count == 100)
    }

    @Test func halfWrittenLastLineIsSkipped() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let url = ChangeLogFile.url(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = ChangeEvent(seq: 1, at: Date(timeIntervalSince1970: 1_790_000_000), event: .created, kind: .log, key: "a", path: "a.md")
        try Data((good.jsonLine() + "\n" + #"{"seq":2,"at":"2026-10-1"#).utf8).write(to: url)
        #expect(try ChangeLogFile.readEvents(root: root) == [good])
    }

    @Test func appendAfterAHalfLineStaysParseable() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let url = ChangeLogFile.url(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let good = ChangeEvent(seq: 1, at: Date(timeIntervalSince1970: 1_790_000_000), event: .created, kind: .log, key: "a", path: "a.md")
        try Data((good.jsonLine() + "\n" + #"{"seq":2,"at":"2026-10-1"#).utf8).write(to: url)
        let written = try await ChangeLog(root: root).append([change(9)])
        #expect(written.map(\.seq) == [2])
        let events = try ChangeLogFile.readEvents(root: root)
        #expect(events.map(\.seq) == [1, 2])
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
    }

    @Test func badLinesInTheMiddleAreSkipped() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let url = ChangeLogFile.url(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let a = ChangeEvent(seq: 1, at: Date(timeIntervalSince1970: 1_790_000_000), event: .created, kind: .log, key: "a", path: "a.md")
        let b = ChangeEvent(seq: 2, at: Date(timeIntervalSince1970: 1_790_000_100), event: .deleted, kind: .log, key: "a", path: "a.md")
        var bytes = Data((a.jsonLine() + "\n").utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0x0A])
        bytes.append(Data("not json\n\(b.jsonLine())\n".utf8))
        try bytes.write(to: url)
        #expect(try ChangeLogFile.readEvents(root: root) == [a, b])
    }

    @Test func eventsUseTheInjectedClock() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let fixed = Date(timeIntervalSince1970: 1_790_000_000)
        let written = try await ChangeLog(root: root, now: { fixed }).append([change(1)])
        #expect(written.first?.at == fixed)
    }

    /// The root may be on a drive that is not connected: the log must not
    /// create it (or anything above it).
    @Test func changeLogNeverCreatesAMissingRoot() async throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let log = ChangeLog(root: base.appendingPathComponent("Drive/Roger", isDirectory: true))
        await #expect(throws: (any Error).self) { try await log.ensureFile() }
        await #expect(throws: (any Error).self) {
            try await log.append([PendingChange(event: .created, kind: .log, key: "Logs/x", path: "Logs/x.md")])
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Drive").path))
    }

    /// The parse uses one decoder and two date formatters for every line.
    /// Several readers at once (roger-mcp answers tool calls in parallel)
    /// must all get every event.
    @Test func parsingIsSafeFromSeveralTasks() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let lines = (1...2_000).map { seq in
            ChangeEvent(seq: seq, at: at, event: .created, kind: .log, key: "Logs/2026/10/\(seq)", path: "Logs/2026/10/\(seq).md").jsonLine()
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { ChangeLogFile.parse(data).count } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 2_000, count: 8))
        #expect(RFC3339.date("2026-10-13T14:32:41.250+02:00") != nil)
    }

    /// `ensureFile` on a log with events (also one cut by a crash) leaves
    /// every byte as it is.
    @Test func ensureFileLeavesAnExistingLogByteForByte() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let log = ChangeLog(root: root)
        try await log.append([PendingChange(event: .created, kind: .log, key: "Logs/a", path: "Logs/a.md")])
        let url = ChangeLogFile.url(root: root)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"at":"#.utf8))
        try handle.close()
        let before = try Data(contentsOf: url)
        try await log.ensureFile()
        #expect(try Data(contentsOf: url) == before)
    }
}
