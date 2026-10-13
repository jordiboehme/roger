import Foundation
import Testing
@testable import Roger

struct ExternalTranscriptRegistryTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addsAndListsWithoutDuplicates() throws {
        let root = try tempRoot()
        let registry = ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("sub/external-transcripts.json"))
        let file = root.appendingPathComponent("talk.mp4.md")
        try Data("x".utf8).write(to: file)
        try registry.add(file)
        try registry.add(file)
        #expect(registry.existingFiles() == [file.standardizedFileURL])
    }

    @Test func prunesMissingFiles() throws {
        let root = try tempRoot()
        let registry = ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("external-transcripts.json"))
        let kept = root.appendingPathComponent("a.md")
        let gone = root.appendingPathComponent("b.md")
        try Data().write(to: kept)
        try Data().write(to: gone)
        try registry.add(kept)
        try registry.add(gone)
        try FileManager.default.removeItem(at: gone)
        #expect(registry.existingFiles() == [kept.standardizedFileURL])
        // The pruned list was saved.
        let fresh = ExternalTranscriptRegistry(fileURL: registry.fileURL)
        #expect(fresh.existingFiles() == [kept.standardizedFileURL])
    }

    @Test func missingRegistryIsEmpty() throws {
        let root = try tempRoot()
        #expect(ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("none.json")).existingFiles().isEmpty)
    }
}
