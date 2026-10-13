import AVFoundation
import Foundation
import Testing
@testable import Roger

struct LogEntryWriterTests {
    private func date(_ h: Int, _ m: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 13; c.hour = h; c.minute = m; c.second = s
        return Calendar.current.date(from: c)!
    }

    private func entry(_ text: String = "Called the supplier about the delayed shipment today") -> LogEntry {
        LogEntry(text: text, startedAt: date(14, 32, 5), endedAt: date(14, 32, 38), presetName: "Log", language: "de")
    }

    @Test func baseNameUsesSeconds() {
        #expect(LogEntryWriter.baseName(for: date(14, 32, 5)) == "2026-10-13 14-32-05")
    }

    @Test func titleUsesFirstSixWords() {
        #expect(LogEntryWriter.title(for: entry()) == "Log 2026-10-13 14:32 - Called the supplier about the delayed")
    }

    @Test func titleStripsTrailingPunctuationAndHandlesShortText() {
        #expect(LogEntryWriter.title(for: entry("Done, finally.")) == "Log 2026-10-13 14:32 - Done, finally")
        #expect(LogEntryWriter.title(for: entry("   ")) == "Log 2026-10-13 14:32")
    }

    @Test func contentHasFrontmatterAndBody() {
        let md = LogEntryWriter.content(for: entry(), audioFileName: nil, generatedAt: date(14, 32, 41))
        #expect(md.hasPrefix("---\ntype: source\n"))
        #expect(md.contains("title: \"Log 2026-10-13 14:32 - Called the supplier about the delayed\"\n"))
        #expect(md.contains("description: \"Log entry recorded with Roger on 2026-10-13 at 14:32.\"\n"))
        #expect(md.contains("tags: [log]\n"))
        #expect(md.contains("source_date: 2026-10-13\n"))
        #expect(md.contains("temporal_confidence: explicit\n"))
        #expect(md.contains("status: stable\n"))
        #expect(md.contains("duration_seconds: 33\n"))
        #expect(md.contains("preset: \"Log\"\n"))
        #expect(md.contains("language: \"de\"\n"))
        #expect(!md.contains("sources:"))
        #expect(md.hasSuffix("---\n\n# Log 2026-10-13 14:32\n\nCalled the supplier about the delayed shipment today\n"))
    }

    @Test func contentListsAudioWhenKept() {
        let md = LogEntryWriter.content(for: entry(), audioFileName: "2026-10-13 14-32-05.m4a", generatedAt: date(14, 32, 41))
        #expect(md.contains("sources:\n  - { id: audio, resource: \"2026-10-13 14-32-05.m4a\" }\n"))
    }

    @Test func contentOmitsUnknownLanguage() {
        let e = LogEntry(text: "x", startedAt: date(9, 0, 0), endedAt: date(9, 0, 2), presetName: "Log", language: nil)
        #expect(!LogEntryWriter.content(for: e, audioFileName: nil, generatedAt: date(9, 0, 3)).contains("language:"))
    }

    @Test func uniqueBaseNameSkipsTakenMdAndM4a() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let base = "2026-10-13 14-32-05"
        #expect(LogEntryWriter.uniqueBaseName(base, in: folder) == base)
        try Data().write(to: folder.appendingPathComponent("\(base).md"))
        #expect(LogEntryWriter.uniqueBaseName(base, in: folder) == "\(base) 1")
        try Data().write(to: folder.appendingPathComponent("\(base) 1.m4a"))
        #expect(LogEntryWriter.uniqueBaseName(base, in: folder) == "\(base) 2")
    }

    @Test func writePutsEntryInMonthFolder() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let url = try await LogEntryWriter.write(entry(), layout: LibraryLayout(root: root), audioSamples: nil)
        #expect(url.path == root.appendingPathComponent("Logs/2026/10/2026-10-13 14-32-05.md").path)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# Log 2026-10-13 14:32"))
    }

    @Test func writeDoesNotOverwriteSameSecond() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let layout = LibraryLayout(root: root)
        let first = try await LogEntryWriter.write(entry(), layout: layout, audioSamples: nil)
        let second = try await LogEntryWriter.write(entry(), layout: layout, audioSamples: nil)
        #expect(first != second)
        #expect(second.lastPathComponent == "2026-10-13 14-32-05 1.md")
    }

    @Test func writeKeepsAudio() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let samples = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.3 }
        let url = try await LogEntryWriter.write(entry(), layout: LibraryLayout(root: root), audioSamples: samples)
        let audio = url.deletingPathExtension().appendingPathExtension("m4a")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        let file = try AVAudioFile(forReading: audio)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 1.0) < 0.2)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("id: audio"))
    }

    @Test func failedAudioStillWritesEntryWithoutSources() async throws {
        struct Boom: Error {}
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let url = try await LogEntryWriter.write(
            entry(), layout: LibraryLayout(root: root), audioSamples: [0, 0.1, 0.2],
            encodeAudio: { _, target in
                try Data("partial".utf8).write(to: target)
                throw Boom()
            }
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("sources:"))
        let audio = url.deletingPathExtension().appendingPathExtension("m4a")
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func unwritableRootThrows() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        // A regular file where the root folder should be: folder creation fails.
        await #expect(throws: (any Error).self) {
            _ = try await LogEntryWriter.write(entry(), layout: LibraryLayout(root: blocker), audioSamples: nil)
        }
    }
}
