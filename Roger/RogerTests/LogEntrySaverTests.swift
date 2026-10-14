import Foundation
import Testing
@testable import Roger

@MainActor
struct LogEntrySaverTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Writes four bytes instead of encoding, so tests need no audio stack.
    private static let fakeEncoder: @Sendable ([Float], URL) throws -> Void = { _, url in
        try Data("m4a!".utf8).write(to: url)
    }

    private func preset(keepAudio: Bool, language: String? = nil) -> DictationPreset {
        var preset = DictationPreset.log
        preset.keepAudio = keepAudio
        preset.language = language
        return preset
    }

    /// `defaultRoot` is never the real `~/Documents/Roger`: by default it is
    /// `root` itself, so a missing root would be created like the default one.
    private func save(
        _ text: String,
        root: URL,
        defaultRoot: URL? = nil,
        preset: DictationPreset,
        detected: String? = nil,
        samples: [Float]? = [0.1, 0.2],
        recorded: inout [URL]
    ) async -> LogEntrySaver.Outcome {
        var urls: [URL] = []
        let saver = LogEntrySaver(
            layout: LibraryLayout(root: root),
            defaultRoot: defaultRoot ?? root,
            encodeAudio: Self.fakeEncoder
        )
        let outcome = await saver.save(
            text, preset: preset, startedAt: start, endedAt: start.addingTimeInterval(12),
            detectedLanguage: detected, samples: samples, recordWritten: { urls.append($0) }
        )
        recorded += urls
        return outcome
    }

    @Test func keepAudioWritesTheRecordingAndListsIt() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        let outcome = await save("Called the supplier", root: root, preset: preset(keepAudio: true), recorded: &recorded)
        guard case .saved(let url) = outcome else {
            Issue.record("expected saved, got \(outcome)")
            return
        }
        #expect(recorded == [url])
        let audio = url.deletingPathExtension().appendingPathExtension("m4a")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("sources:\n  - { id: audio, resource: \"\(audio.lastPathComponent)\" }\n"))
    }

    @Test func withoutKeepAudioNoRecordingIsKept() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        let outcome = await save("Called the supplier", root: root, preset: preset(keepAudio: false), recorded: &recorded)
        guard case .saved(let url) = outcome else {
            Issue.record("expected saved, got \(outcome)")
            return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == [url.lastPathComponent])
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("sources:"))
    }

    @Test func emptyTextWritesAndRecordsNothing() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        #expect(await save("  \n", root: root, preset: preset(keepAudio: true), recorded: &recorded) == .empty)
        #expect(recorded.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func aFailedWriteRecordsNothing() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        // A plain file where the Logs folder should be: the month folder
        // cannot be created.
        try Data("x".utf8).write(to: root.appendingPathComponent("Logs"))
        var recorded: [URL] = []
        let outcome = await save("Called the supplier", root: root, preset: preset(keepAudio: false), recorded: &recorded)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(recorded.isEmpty)
    }

    /// A custom library folder on a drive that is not connected: nothing
    /// is created and the outcome says so, so the coordinator can keep the
    /// text on the clipboard.
    @Test func aMissingCustomRootIsReportedAndNotCreated() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let custom = base.appendingPathComponent("Drive/Roger")
        var recorded: [URL] = []
        let outcome = await save(
            "Called the supplier", root: custom, defaultRoot: base.appendingPathComponent("Documents/Roger"),
            preset: preset(keepAudio: true), recorded: &recorded
        )
        #expect(outcome == .libraryMissing(LibraryRootMissingError(path: custom.path).localizedDescription))
        #expect(recorded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Drive").path))
    }

    /// A plain file where the custom root should be counts as a missing root.
    @Test func aFileAsTheRootCountsAsMissing() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let notAFolder = base.appendingPathComponent("file")
        try Data("x".utf8).write(to: notAFolder)
        var recorded: [URL] = []
        let outcome = await save(
            "Called the supplier", root: notAFolder, defaultRoot: base.appendingPathComponent("Documents/Roger"),
            preset: preset(keepAudio: false), recorded: &recorded
        )
        guard case .libraryMissing = outcome else {
            Issue.record("expected libraryMissing, got \(outcome)")
            return
        }
        #expect(recorded.isEmpty)
    }

    @Test func theDetectedLanguageWinsOverThePresetPin() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        guard case .saved(let pinned) = await save("Hallo", root: root, preset: preset(keepAudio: false, language: "de"), recorded: &recorded),
              case .saved(let detected) = await save("Hello", root: root, preset: preset(keepAudio: false, language: "de"), detected: "en", recorded: &recorded)
        else {
            Issue.record("expected two saved entries")
            return
        }
        #expect(try String(contentsOf: pinned, encoding: .utf8).contains("language: \"de\"\n"))
        #expect(try String(contentsOf: detected, encoding: .utf8).contains("language: \"en\"\n"))
    }
}
