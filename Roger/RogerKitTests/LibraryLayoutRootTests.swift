import Foundation
import Testing
@testable import RogerKit

struct LibraryLayoutRootTests {
    @Test func theDefaultRootIsCreated() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let root = base.appendingPathComponent("Documents/Roger", isDirectory: true)
        #expect(LibraryLayout.createRootIfDefault(LibraryLayout(root: root), defaultRoot: root))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aMissingCustomRootIsLeftAlone() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let custom = base.appendingPathComponent("Volumes/Drive/Roger", isDirectory: true)
        let defaultRoot = base.appendingPathComponent("Documents/Roger", isDirectory: true)
        #expect(!LibraryLayout.createRootIfDefault(LibraryLayout(root: custom), defaultRoot: defaultRoot))
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Volumes").path))
    }

    @Test func anExistingCustomRootIsFine() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        #expect(LibraryLayout.createRootIfDefault(LibraryLayout(root: base), defaultRoot: base.appendingPathComponent("Other")))
    }

    @Test func aPlainFileIsNotARoot() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let file = base.appendingPathComponent("Roger")
        try Data().write(to: file)
        #expect(!LibraryLayout.createRootIfDefault(LibraryLayout(root: file), defaultRoot: base.appendingPathComponent("Other")))
    }
}
