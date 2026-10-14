import Foundation
import Testing
@testable import RogerKit

struct LibraryLocatorTests {
    private let none: @Sendable () -> RogerPreferences = { RogerPreferences(libraryRoot: nil, extraScanFolders: []) }

    @Test func argumentWinsOverPreferences() {
        let locator = LibraryLocator(
            argument: "/tmp/ArgLibrary",
            preferences: { RogerPreferences(libraryRoot: "/tmp/PrefLibrary", extraScanFolders: ["/tmp/Old"]) },
            defaultRoot: URL(fileURLWithPath: "/tmp/Default")
        )
        let location = locator.locate()
        #expect(location.root.path == "/tmp/ArgLibrary")
        #expect(location.extraFolders.isEmpty)
        #expect(!location.usesRogerSettings)
    }

    @Test func preferencesThenDefault() {
        let fromPrefs = LibraryLocator(
            argument: nil,
            preferences: { RogerPreferences(libraryRoot: "/tmp/PrefLibrary", extraScanFolders: ["/tmp/Old"]) },
            defaultRoot: URL(fileURLWithPath: "/tmp/Default")
        ).locate()
        #expect(fromPrefs.root.path == "/tmp/PrefLibrary")
        #expect(fromPrefs.extraFolders.map(\.path) == ["/tmp/Old"])
        #expect(fromPrefs.usesRogerSettings)
        let fallback = LibraryLocator(argument: nil, preferences: none, defaultRoot: URL(fileURLWithPath: "/tmp/Default")).locate()
        #expect(fallback.root.path == "/tmp/Default")
    }

    @Test func probeTellsMissingFromDenied() throws {
        let root = try TempDir.make()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ChangeLogFile.folder(root: root).path)
            TempDir.remove(root)
        }
        #expect(LibraryLocator.probe(root: root) == .notSetUp)
        #expect(LibraryLocator.probe(root: root.appendingPathComponent("nope")) == .notSetUp)
        try FileManager.default.createDirectory(at: ChangeLogFile.folder(root: root), withIntermediateDirectories: true)
        try Data().write(to: ChangeLogFile.url(root: root))
        #expect(LibraryLocator.probe(root: root) == .ready)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ChangeLogFile.folder(root: root).path)
        #expect(LibraryLocator.probe(root: root) == .notReadable)
    }
}
