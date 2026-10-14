import Foundation
import Testing
@testable import Roger

@MainActor
struct LibraryMigrationRunTests {
    /// `<base>/Roger Recordings/<name>` with a `mic.m4a`.
    @discardableResult
    private func oldSession(_ base: URL, _ name: String = "2026-01-02 10-00") throws -> URL {
        let folder = base.appendingPathComponent("Roger Recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: folder.appendingPathComponent("mic.m4a"))
        return folder
    }

    /// The library is `<base>/Roger`. It counts as the default root (so it
    /// may be created) unless `defaultRoot` says otherwise.
    private func input(
        _ base: URL,
        extras: [URL] = [],
        transcripts: URL? = nil,
        old: URL? = nil,
        defaultRoot: URL? = nil
    ) -> LibraryMigrationRun.Input {
        let root = base.appendingPathComponent("Roger", isDirectory: true)
        return LibraryMigrationRun.Input(
            layout: LibraryLayout(root: root),
            extraFolders: extras,
            legacyTranscriptFolder: transcripts,
            legacyMeetingsFolder: old ?? base.appendingPathComponent("Roger Recordings", isDirectory: true),
            defaultRoot: defaultRoot ?? root
        )
    }

    private func oldFolder(_ base: URL) -> URL {
        base.appendingPathComponent("Roger Recordings", isDirectory: true)
    }

    @Test func moveBringsTheSessionsIntoTheLibrary() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        try oldSession(base)
        var questions: [Int] = []
        let result = LibraryMigrationRun.run(input(base)) { count, _ in
            questions.append(count)
            return true
        }
        #expect(questions == [1])
        #expect(result.asked)
        #expect(result.finished)
        #expect(result.extraFolders.isEmpty)
        #expect(result.failedCount == 0)
        #expect(result.moved.map(\.lastPathComponent) == ["2026-01-02 10-00"])
        let moved = base.appendingPathComponent("Roger/Meetings/2026/01/2026-01-02 10-00/mic.m4a")
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    /// An earlier launch kept the old folder as an extra folder (library
    /// missing). A later move without failures takes it out again.
    @Test func aLaterMoveRemovesTheOldFolderFromTheExtraFolders() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        try oldSession(base)
        let other = base.appendingPathComponent("Other", isDirectory: true)
        let result = LibraryMigrationRun.run(input(base, extras: [other, oldFolder(base)])) { _, _ in true }
        #expect(result.finished)
        #expect(result.failedCount == 0)
        #expect(result.moved.count == 1)
        #expect(result.extraFolders == [other])
    }

    @Test func keepInPlaceMakesTheOldFolderAnExtraFolder() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try oldSession(base)
        let result = LibraryMigrationRun.run(input(base)) { _, _ in false }
        #expect(result.finished)
        #expect(result.extraFolders == [oldFolder(base)])
        #expect(result.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: session.path))
    }

    @Test func noSessionsMeansNoQuestion() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        try FileManager.default.createDirectory(at: oldFolder(base), withIntermediateDirectories: true)
        let result = LibraryMigrationRun.run(input(base)) { _, _ in
            Issue.record("asked without sessions")
            return true
        }
        #expect(!result.asked)
        #expect(result.finished)
        #expect(result.extraFolders.isEmpty)
    }

    @Test func anOldFolderInsideTheLibraryIsLeftAlone() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let meetings = base.appendingPathComponent("Roger/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings.appendingPathComponent("2026-01-02 10-00"), withIntermediateDirectories: true)
        try Data().write(to: meetings.appendingPathComponent("2026-01-02 10-00/mic.m4a"))
        let result = LibraryMigrationRun.run(input(base, old: meetings)) { _, _ in
            Issue.record("asked for a folder inside the library")
            return true
        }
        #expect(!result.asked)
        #expect(result.finished)
    }

    @Test func theTranscriptFolderIsAddedOnce() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let transcripts = base.appendingPathComponent("My Transcripts", isDirectory: true)
        let result = LibraryMigrationRun.run(input(base, extras: [transcripts], transcripts: transcripts)) { _, _ in true }
        #expect(result.extraFolders == [transcripts])
    }

    @Test func aFailedMoveKeepsTheOldFolderAsAnExtraFolder() throws {
        let base = try TempFolder.make()
        let root = base.appendingPathComponent("Roger", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            TempFolder.remove(base)
        }
        let session = try oldSession(base)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let result = LibraryMigrationRun.run(input(base)) { _, _ in true }
        #expect(result.failedCount == 1)
        #expect(result.finished)
        #expect(result.extraFolders == [oldFolder(base)])
        #expect(FileManager.default.fileExists(atPath: session.path))
    }

    /// A missing custom library folder (drive not connected): no question,
    /// nothing is created, the old folder is still scanned and the
    /// migration is offered again next launch.
    @Test func aMissingCustomRootWaits() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try oldSession(base)
        let result = LibraryMigrationRun.run(input(base, defaultRoot: base.appendingPathComponent("Documents/Roger"))) { _, _ in
            Issue.record("asked without a library folder")
            return true
        }
        #expect(!result.asked)
        #expect(!result.finished)
        #expect(result.extraFolders == [oldFolder(base)])
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Roger").path))
        #expect(FileManager.default.fileExists(atPath: session.path))
    }

    /// The custom root disappears while the question is open (drive
    /// ejected): the move throws before anything moves, the old folder is
    /// still scanned and the migration is offered again next launch.
    @Test func aRootThatDisappearsDuringTheQuestionWaits() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try oldSession(base)
        let root = base.appendingPathComponent("Roger", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = LibraryMigrationRun.run(input(base, defaultRoot: base.appendingPathComponent("Documents/Roger"))) { _, _ in
            try? FileManager.default.removeItem(at: root)
            return true
        }
        #expect(result.asked)
        #expect(!result.finished)
        #expect(result.moved.isEmpty)
        #expect(result.extraFolders == [oldFolder(base)])
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: session.path))
    }
}
