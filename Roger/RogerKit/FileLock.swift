import Foundation

extension POSIXError {
    /// The error for the current `errno`.
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
