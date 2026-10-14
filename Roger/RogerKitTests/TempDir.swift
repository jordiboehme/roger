import Foundation

/// Unique `RogerKitTests-<UUID>` folders in the temporary directory. Pair
/// `make()` with `defer { TempDir.remove(url) }`.
enum TempDir {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
