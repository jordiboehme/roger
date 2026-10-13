import CoreServices
import Foundation

/// Thin wrapper around an `FSEventStream` with file-level events. Reports
/// changed paths (real paths, such as `/private/var/...`) in batches,
/// coalesced over `latency` seconds, on a private queue. `mustRescan` is
/// true when FSEvents dropped events or a watched root changed, so the
/// caller should read everything again. Call `stop()` before releasing it.
final class LibraryFolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void

    let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.jordiboehme.roger.library-watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 0.5, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// False when there is nothing to watch or FSEvents refused the stream.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<LibraryFolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
                let rescan = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                )
                var mustRescan = false
                for i in 0..<count where eventFlags[i] & rescan != 0 { mustRescan = true }
                watcher.handler(changed, mustRescan)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// No callback runs after this returns.
    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
        // A callback may already be running; wait so it never touches a released watcher.
        queue.sync {}
    }
}
