import Foundation
import Testing
@testable import Roger

struct MeetingSessionRootTests {
    @Test func aMissingCustomRootIsNotCreated() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let custom = base.appendingPathComponent("Drive/Roger")
        #expect(throws: LibraryRootMissingError(path: custom.path)) {
            try MeetingSession.create(layout: LibraryLayout(root: custom), defaultRoot: base.appendingPathComponent("Documents/Roger"))
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Drive").path))
    }

    @Test func theDefaultRootIsCreated() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let root = base.appendingPathComponent("Documents/Roger")
        let session = try MeetingSession.create(layout: LibraryLayout(root: root), defaultRoot: root)
        #expect(FileManager.default.fileExists(atPath: session.folder.path))
    }

    @Test func anExistingCustomRootGetsItsSessionFolder() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try MeetingSession.create(layout: LibraryLayout(root: base), defaultRoot: base.appendingPathComponent("Other"))
        #expect(FileManager.default.fileExists(atPath: session.folder.path))
    }
}
