#if DEBUG
import AppKit
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "SettingsSnapshot")

/// Debug-only dev tool: renders every settings pane into PNG files, then
/// Roger quits. Start it with
/// `Roger -RogerSnapshotDir <folder> -RogerSnapshotSettings YES`
/// (or `scripts/settings-snapshots.sh <folder>`). Per pane it writes
/// `settings-<pane>.png` (light, tall enough for the whole pane),
/// `settings-<pane>-dark.png` and `settings-<pane>-min.png` (the minimum
/// window size, to see what gets cut off). The run remembers no pane and
/// no window frame, and it changes no setting.
@MainActor
enum SettingsSnapshotRunner {
    static let tallSize = NSSize(width: 720, height: 1000)
    /// The run quits on its own after this, whatever state it is in.
    static let watchdog: TimeInterval = 150

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "RogerSnapshotSettings")
    }

    /// One image per pane and variant.
    struct Variant {
        let suffix: String
        let size: NSSize
        let appearance: NSAppearance.Name?
    }

    static let variants = [
        Variant(suffix: "", size: tallSize, appearance: .aqua),
        Variant(suffix: "-dark", size: tallSize, appearance: .darkAqua),
        Variant(suffix: "-min", size: SettingsWindowController.minimumSize, appearance: .aqua),
    ]

    static func fileName(_ pane: SettingsPane, _ variant: Variant) -> String {
        "settings-\(pane.rawValue)\(variant.suffix).png"
    }

    static func run(controller: SettingsWindowController, folder: URL) async {
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
            logger.error("Settings snapshot run did not finish in time")
            exit(2)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.error("Settings snapshot run: cannot create \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        controller.show(.general)
        guard let window = controller.window else {
            logger.error("Settings snapshot run: no settings window")
            return
        }
        window.isRestorable = false
        // The first layout of the window takes longer.
        await LibrarySnapshotRunner.settle(seconds: 2)

        for pane in SettingsPane.allCases {
            controller.show(pane)
            // Agents looks for coding agents and Claude Desktop first.
            await LibrarySnapshotRunner.settle(seconds: pane == .agents ? 5 : 1.5)
            for variant in variants {
                window.appearance = variant.appearance.flatMap(NSAppearance.init(named:))
                window.setContentSize(variant.size)
                window.center()
                await LibrarySnapshotRunner.settle(seconds: 0.8)
                LibrarySnapshotRunner.render(window, fileName(pane, variant), into: folder)
            }
        }
        window.appearance = nil
    }
}
#endif
