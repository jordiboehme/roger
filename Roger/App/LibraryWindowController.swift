import AppKit
import SwiftUI

/// Owns the library window: an NSWindow hosting `LibraryView`, created once
/// and reused. While it is open, Roger is a regular app (Dock icon, Cmd-Tab,
/// main menu with Settings and Cmd-,). When it closes, Roger is a menu bar
/// app again. A SwiftUI `Window` scene is not used because `openWindow` is
/// not reachable from the AppKit popover.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "RogerLibraryWindow"

    private let coordinator: AppCoordinator
    private let indexStore: LibraryIndexStore
    private var window: NSWindow?
    private var model: LibraryModel?
    private var scope: LibraryScanScope?
    /// True from `show` until the window closes (also while miniaturised).
    private(set) var isOpen = false

    init(coordinator: AppCoordinator, indexStore: LibraryIndexStore) {
        self.coordinator = coordinator
        self.indexStore = indexStore
    }

    func show(selecting url: URL? = nil) {
        let window = self.window ?? makeWindow()
        refreshScope()
        if let url { model?.select(url: url) }
        isOpen = true
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // Right after the policy change the menu bar can still belong to the
        // previous app. Activating on the next run loop turn fixes that.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Points the window at the current library folder and extra folders.
    func refreshScope() {
        let current = currentScope()
        guard current != scope else { return }
        scope = current
        model?.replaceIndex(indexStore.index(for: current))
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func currentScope() -> LibraryScanScope {
        LibraryScanScope(
            layout: coordinator.appState.libraryLayout,
            extraFolders: coordinator.appState.extraScanFolders
        )
    }

    private func makeWindow() -> NSWindow {
        let scope = currentScope()
        self.scope = scope
        let model = LibraryModel(index: indexStore.index(for: scope))
        let root = LibraryView(model: model, onScopeChange: { [weak self] in self?.refreshScope() })
            .environment(coordinator)
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // Keep the saved frame; do not let SwiftUI resize the window.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.title = "Roger Library"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 900, height: 520)
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)

        model.start()
        self.model = model
        self.window = window
        return window
    }
}
