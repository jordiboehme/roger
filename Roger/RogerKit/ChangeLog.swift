import Foundation

/// Where the log lives and how readers read it. Readers take no lock: a
/// line is written with one `write` on an `O_APPEND` descriptor, and a line
/// that is not complete yet (or was cut by a crash) does not parse and is
/// skipped.
public enum ChangeLogFile {
    public static func folder(root: URL) -> URL {
        root.appendingPathComponent(".roger", isDirectory: true)
    }

    public static func url(root: URL) -> URL {
        folder(root: root).appendingPathComponent("changes.jsonl")
    }

    /// Every line that parses, in file order. Lines are split on `\n` bytes
    /// first, so a broken UTF-8 sequence spoils only its own line.
    public static func parse(_ data: Data) -> [ChangeEvent] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { ChangeEvent.parse(Data($0)) }
    }

    public static func readEvents(root: URL) throws -> [ChangeEvent] {
        parse(try Data(contentsOf: url(root: root)))
    }
}

/// The app's writer for `<root>/.roger/changes.jsonl`. Every operation runs
/// under an exclusive `flock` on the log file: read all events, decide what
/// to append, append it with one `write`. That makes `seq` unique across
/// processes (a Debug and a Release Roger) and across actor instances.
public actor ChangeLog {
    public nonisolated let root: URL
    public nonisolated let fileURL: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.fileURL = ChangeLogFile.url(root: root)
        self.now = now
    }

    @discardableResult
    public func append(_ changes: [PendingChange]) throws -> [ChangeEvent] {
        try locked { _ in (changes, ()) }.written
    }

    /// Creates `.roger/changes.jsonl` when it is missing.
    public func ensureFile() throws {
        _ = try locked { _ in ([], ()) }
    }

    /// Runs `decide` with all events under the lock and appends what it
    /// returns. `seq` continues after the highest valid seq in the file.
    /// When the file does not end with a newline (a crash cut the last
    /// line), one is written first so the new lines parse.
    func locked<T: Sendable>(
        _ decide: ([ChangeEvent]) throws -> ([PendingChange], T)
    ) throws -> (written: [ChangeEvent], result: T) {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try FileLock.withExclusiveLock(at: fileURL, flags: O_RDWR | O_APPEND | O_CREAT) { fd in
            let existing = try Self.readAll(fd)
            let events = ChangeLogFile.parse(existing)
            let (pending, result) = try decide(events)
            guard !pending.isEmpty else { return ([], result) }

            var seq = events.map(\.seq).max() ?? 0
            let at = now()
            var text = (existing.isEmpty || existing.last == 0x0A) ? "" : "\n"
            var written: [ChangeEvent] = []
            for change in pending {
                seq += 1
                let event = ChangeEvent(seq: seq, at: at, event: change.event, kind: change.kind, key: change.key, path: change.path)
                written.append(event)
                text += event.jsonLine() + "\n"
            }
            try Self.writeAll(fd, Data(text.utf8))
            return (written, result)
        }
    }

    private static func readAll(_ fd: Int32) throws -> Data {
        var data = Data()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError.current
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            offset += off_t(count)
        }
    }

    /// One `write` call; loops only if the kernel takes fewer bytes.
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, base + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current
                }
                offset += count
            }
        }
    }
}
