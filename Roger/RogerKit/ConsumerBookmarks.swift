import Foundation

public struct ConsumerBookmark: Equatable, Sendable {
    public let seq: Int
    public let updatedAt: Date

    public init(seq: Int, updatedAt: Date) {
        self.seq = seq
        self.updatedAt = updatedAt
    }
}

public struct NamedBookmark: Equatable, Sendable {
    public let name: String
    public let bookmark: ConsumerBookmark
}

public struct AckResult: Equatable, Sendable {
    public let previous: Int
    public let current: Int

    public init(previous: Int, current: Int) {
        self.previous = previous
        self.current = current
    }
}

public enum ConsumerBookmarkError: Error, Equatable, LocalizedError {
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "\"\(name)\" is not a valid consumer name. Use 1 to 64 characters: a-z, 0-9 and \"-\", starting with a letter or digit."
        }
    }
}

/// `<root>/.roger/consumers/<name>.json`. Every change runs under an
/// exclusive `flock` on `consumers/.lock` and replaces the file with a
/// temp file plus `rename`, so two `roger-mcp` processes acking at once
/// end at the higher seq and a reader never sees half a file.
public struct ConsumerBookmarks: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var folder: URL {
        ChangeLogFile.folder(root: root).appendingPathComponent("consumers", isDirectory: true)
    }

    /// `^[a-z0-9][a-z0-9-]{0,63}$`, checked by hand so a trailing newline
    /// cannot slip through a regex `$`.
    public static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...64).contains(scalars.count) else { return false }
        func lowerOrDigit(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        return lowerOrDigit(scalars[0]) && scalars.allSatisfy { lowerOrDigit($0) || $0 == "-" }
    }

    public func bookmark(_ name: String) throws -> ConsumerBookmark? {
        try validate(name)
        return Self.read(fileURL(name))
    }

    /// Valid bookmarks, sorted by name. Files with other names or broken
    /// content are left out.
    public func all() -> [NamedBookmark] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .map { String($0.dropLast(5)) }
            .filter(Self.isValidName)
            .sorted()
            .compactMap { name in Self.read(fileURL(name)).map { NamedBookmark(name: name, bookmark: $0) } }
    }

    /// Moves the bookmark to `upTo` when that is higher. Never backwards.
    @discardableResult
    public func ack(_ name: String, upTo: Int, now: Date = Date()) throws -> AckResult {
        try validate(name)
        return try withLock {
            let previous = Self.read(fileURL(name))?.seq ?? 0
            guard upTo > previous else { return AckResult(previous: previous, current: previous) }
            try write(ConsumerBookmark(seq: upTo, updatedAt: now), name: name)
            return AckResult(previous: previous, current: upTo)
        }
    }

    /// "Start over" in the Agents tab: the bookmark goes back to 0.
    public func reset(_ name: String, now: Date = Date()) throws {
        try validate(name)
        try withLock { try write(ConsumerBookmark(seq: 0, updatedAt: now), name: name) }
    }

    /// "Forget" in the Agents tab: the bookmark file goes away.
    public func forget(_ name: String) throws {
        try validate(name)
        try withLock {
            let url = fileURL(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func fileURL(_ name: String) -> URL {
        folder.appendingPathComponent("\(name).json")
    }

    private func validate(_ name: String) throws {
        guard Self.isValidName(name) else { throw ConsumerBookmarkError.invalidName(name) }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try FileLock.withExclusiveLock(
            at: folder.appendingPathComponent(".lock"), flags: O_RDWR | O_CREAT
        ) { _ in try body() }
    }

    /// The temp file is `fsync`ed before the `rename`, so a crash never
    /// leaves an empty bookmark in place of a good one.
    private func write(_ bookmark: ConsumerBookmark, name: String) throws {
        let text = "{\"seq\":\(bookmark.seq),\"updatedAt\":\"\(RFC3339.string(bookmark.updatedAt))\"}\n"
        let temp = folder.appendingPathComponent(".\(name).json.\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError.current }
        do {
            try FileIO.writeAll(fd, Data(text.utf8))
            try FileIO.sync(fd)
            close(fd)
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, fileURL(name).path) == 0 else {
            let error = POSIXError.current
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private struct Raw: Decodable {
        let seq: Int
        let updatedAt: String
    }

    private static func read(_ url: URL) -> ConsumerBookmark? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data),
              raw.seq >= 0,
              let date = RFC3339.date(raw.updatedAt)
        else { return nil }
        return ConsumerBookmark(seq: raw.seq, updatedAt: date)
    }
}
