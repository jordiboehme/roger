import Foundation

/// Unique `RogerTests-<UUID>` folders in the temporary directory. Tests pair
/// `make()` with `defer { TempFolder.remove(url) }` so nothing is left behind.
enum TempFolder {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
