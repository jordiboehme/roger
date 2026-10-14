import Foundation
import Testing
@testable import RogerKit

struct FileIOTests {
    @Test func writeAllAndSyncPutTheBytesOnDisk() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let url = folder.appendingPathComponent("data")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        try #require(fd >= 0)
        defer { close(fd) }
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        try FileIO.writeAll(fd, data)
        try FileIO.sync(fd)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func syncReportsAnError() {
        #expect(throws: POSIXError.self) { try FileIO.sync(-1) }
    }
}
