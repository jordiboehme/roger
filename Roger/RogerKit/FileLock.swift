import Foundation

extension POSIXError {
    /// The error for the current `errno`.
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Writes to a descriptor, shared by the change log and the bookmarks.
enum FileIO {
    /// Loops only if the kernel takes fewer bytes.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
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

    /// `fsync`: the bytes are on the disk before the caller goes on.
    static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            guard errno == EINTR else { throw POSIXError.current }
        }
    }
}

/// An exclusive `flock` on a file, shared by the change log and the
/// consumer bookmarks. The lock works across processes.
enum FileLock {
    /// Opens `url` (flags are added to `O_CLOEXEC`), takes the exclusive
    /// lock, runs `body` with the descriptor and releases the lock.
    static func withExclusiveLock<T>(
        at url: URL,
        flags: Int32,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let fd = open(url.path, flags | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError.current }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError.current }
        }
        defer { flock(fd, LOCK_UN) }
        return try body(fd)
    }
}
