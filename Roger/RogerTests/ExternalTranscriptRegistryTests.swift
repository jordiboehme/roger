import Foundation
import Testing
@testable import Roger

struct ExternalTranscriptRegistryTests {
    @Test func addsAndListsWithoutDuplicates() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let registry = ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("sub/external-transcripts.json"))
        let file = root.appendingPathComponent("talk.mp4.md")
        try Data("x".utf8).write(to: file)
        try registry.add(file)
        try registry.add(file)
        #expect(registry.existingFiles() == [file.standardizedFileURL])
    }

    @Test func prunesMissingFiles() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
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
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        #expect(ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("none.json")).existingFiles().isEmpty)
    }

    @Test func unreadableRegistryIsMovedAsideNotOverwritten() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let registry = ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("external-transcripts.json"))
        let garbage = Data("not json".utf8)
        let first = root.appendingPathComponent("a.md")
        let second = root.appendingPathComponent("b.md")
        try Data().write(to: first)
        try Data().write(to: second)

        func corruptCopies() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("external-transcripts.corrupt-") && $0.pathExtension == "json" }
        }

        try garbage.write(to: registry.fileURL)
        try registry.add(first)
        #expect(ExternalTranscriptRegistry(fileURL: registry.fileURL).existingFiles() == [first.standardizedFileURL])
        let copies = try corruptCopies()
        #expect(copies.count == 1)
        #expect(try copies.first.map { try Data(contentsOf: $0) } == garbage)

        // A second bad file in the same second does not replace the first copy.
        try garbage.write(to: registry.fileURL)
        try registry.add(second)
        #expect(try corruptCopies().count == 2)
        #expect(ExternalTranscriptRegistry(fileURL: registry.fileURL).existingFiles() == [second.standardizedFileURL])
    }
}
