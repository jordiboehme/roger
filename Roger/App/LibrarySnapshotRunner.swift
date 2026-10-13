#if DEBUG
import AppKit
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibrarySnapshot")

/// Debug-only dev tool: renders the library window into PNG files, one per
/// state, then Roger quits. Start it with
/// `Roger -RogerSnapshotDir <folder> -libraryRoot <sample library> -extraScanFolders '()'`
/// (see `scripts/make-sample-library.sh`). The arguments only live in the
/// argument domain of that launch, so the saved settings stay as they are.
/// Renders through the window's own views, so no screen recording
/// permission is needed.
@MainActor
enum LibrarySnapshotRunner {
    static let windowSize = NSSize(width: 1200, height: 760)
    /// Appears in several sample entries.
    static let searchTerm = "roadmap"
    /// Appears in none.
    static let emptySearchTerm = "zeppelin"
    /// The run quits on its own after this, whatever state it is in.
    static let watchdog: TimeInterval = 75

    static var requestedFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: "RogerSnapshotDir"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Without the real external-transcripts list, so nothing outside the
    /// sample library shows up.
    static func indexStore() -> LibraryIndexStore {
        LibraryIndexStore(externalFiles: { [] }, externalListURL: nil, watchesFileSystem: true)
    }

    static func run(controller: LibraryWindowController, coordinator: AppCoordinator, folder: URL) async {
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
            logger.error("Snapshot run did not finish in time")
            exit(2)
        }
        guard let window = controller.snapshotWindow, let model = controller.snapshotModel else {
            logger.error("Snapshot run: no library window")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.error("Snapshot run: cannot create \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        // Keep the saved window frame and state as they are.
        window.setFrameAutosaveName("")
        window.isRestorable = false
        window.setFrame(NSRect(origin: window.frame.origin, size: windowSize), display: true)
        window.center()

        guard await waitUntil(seconds: 10, { !model.isLoading }) else {
            logger.error("Snapshot run: the index did not load")
            return
        }

        // 1. Everything, newest first, newest item selected. The first
        // layout of the list takes longer.
        model.sidebar = .all
        await settle()
        select(model.results.first, in: model)
        await settle(seconds: 2)
        render(window, "01-all.png", into: folder)

        // 2. Logs with a log entry selected.
        model.sidebar = .kind(.log)
        await waitUntil(seconds: 5) { !model.results.isEmpty && model.results.allSatisfy { $0.kind == .log } }
        select(model.results.first, in: model)
        await settle()
        render(window, "02-logs.png", into: folder)

        // 3. A meeting with screenshots (and the extra files of a retry).
        model.sidebar = .kind(.meeting)
        await waitUntil(seconds: 5) { !model.results.isEmpty && model.results.allSatisfy { $0.kind == .meeting } }
        select(model.results.first { $0.screenshotCount > 0 } ?? model.results.first, in: model)
        await settle(seconds: 2)
        render(window, "03-meeting.png", into: folder)

        // 4. A search that matches several items.
        model.sidebar = .all
        model.searchText = searchTerm
        await waitUntil(seconds: 5) { model.appliedSearch == searchTerm }
        await settle()
        select(model.results.first { $0.kind == .log } ?? model.results.first, in: model)
        await settle()
        render(window, "04-search.png", into: folder)

        // 5. Editing a log entry. Never saved, cancelled right after.
        model.searchText = ""
        model.sidebar = .kind(.log)
        await waitUntil(seconds: 5) {
            model.appliedSearch.isEmpty && !model.results.isEmpty && model.results.allSatisfy { $0.kind == .log }
        }
        if let item = model.results.first {
            select(item, in: model)
            await settle()
            do {
                model.beginEditing(item, document: try LibraryDocument.load(item.url))
                await settle()
                render(window, "05-edit.png", into: folder)
            } catch {
                logger.error("Snapshot run: cannot load \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            model.editingItem = nil
            await settle()
        }

        // 6. A search without results.
        model.sidebar = .all
        model.searchText = emptySearchTerm
        await waitUntil(seconds: 5) { model.appliedSearch == emptySearchTerm }
        await settle()
        render(window, "06-empty.png", into: folder)

        // 7. Unfinished meetings, when there are any.
        model.searchText = ""
        await waitUntil(seconds: 5) { model.appliedSearch.isEmpty }
        if !coordinator.pendingMeetingSessions.isEmpty {
            model.selection = []
            model.sidebar = .unfinished
            await settle()
            render(window, "07-unfinished.png", into: folder)
        } else {
            logger.notice("Snapshot run: no unfinished meetings, 07 skipped")
        }
    }

    private static func select(_ item: LibraryItem?, in model: LibraryModel) {
        model.selection = item.map { [$0.id] } ?? []
    }

    private static func settle(seconds: Double = 1) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Polls `condition` every 100 ms. False when it timed out.
    @discardableResult
    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// The whole window, title bar and toolbar included, at its backing scale.
    private static func render(_ window: NSWindow, _ name: String, into folder: URL) {
        window.displayIfNeeded()
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            logger.error("Snapshot run: cannot render \(name, privacy: .public)")
            return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            logger.error("Snapshot run: cannot encode \(name, privacy: .public)")
            return
        }
        do {
            try data.write(to: folder.appendingPathComponent(name))
            logger.notice("Snapshot \(name, privacy: .public): \(rep.pixelsWide)x\(rep.pixelsHigh), scale \(window.backingScaleFactor)")
        } catch {
            logger.error("Snapshot run: cannot write \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
