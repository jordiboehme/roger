import AppKit
import SwiftUI

/// Owns the library window: an NSWindow hosting `LibraryView`, created once
/// and reused. While it is open, Roger is a regular app (Dock icon, Cmd-Tab,
/// main menu with Settings and Cmd-,), counted by `AppWindowPresence`
/// together with the settings window. A SwiftUI `Window` scene is not used
/// because `openWindow` is not reachable from the AppKit popover.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "RogerLibraryWindow"

    private let coordinator: AppCoordinator
    private let indexStore: LibraryIndexStore
    private let presence: AppWindowPresence
    private var window: NSWindow?
    private var model: LibraryModel?
    private var scope: LibraryScanScope?
    /// True from `show` until the window closes (also while miniaturised).
    private(set) var isOpen = false
    private var activationObserver: NSObjectProtocol?

    #if DEBUG
    /// For `LibrarySnapshotRunner` only.
    var snapshotWindow: NSWindow? { window }
    var snapshotModel: LibraryModel? { model }
    #endif

    init(coordinator: AppCoordinator, indexStore: LibraryIndexStore, presence: AppWindowPresence = .shared) {
        self.coordinator = coordinator
        self.indexStore = indexStore
        self.presence = presence
        super.init()
        // A library folder on a drive that was connected meanwhile, or
        // one that was deleted: look again whenever Roger becomes active.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, let model = self.model else { return }
                Task { await model.recheckLibraryRoot() }
            }
        }
    }

    func show(selecting url: URL? = nil) {
        let window = self.window ?? makeWindow()
        refreshScope()
        if let url { model?.select(url: url) }
        // Reopened after a close: follow changes again and load once.
        model?.resume()
        // The app may already be active (no activation notification), so a
        // drive connected meanwhile is noticed here.
        if let model { Task { await model.recheckLibraryRoot() } }
        isOpen = true
        // Before the window is shown, so the Dock icon does not flash.
        presence.enter(.library)
        if window.isMiniaturized { window.deminiaturize(nil) }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmUnsavedEdit()
    }

    /// Asks what to do with an unsaved body edit before the window closes
    /// or Roger quits. True when it may go ahead.
    func confirmUnsavedEdit() -> Bool {
        guard let model, model.hasUnsavedChanges, let item = model.editingItem else { return true }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(item.title)\"?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let message: String?
            do {
                let outcome = try model.saveEdit(
                    overwrite: false,
                    activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder
                )
                message = outcome.failureMessage
            } catch {
                message = error.localizedDescription
            }
            guard let message else { return true }
            let failed = NSAlert()
            failed.messageText = "Roger could not save your changes"
            failed.informativeText = message
            failed.runModal()
            return false
        case .alertSecondButtonReturn:
            model.editingItem = nil
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        isOpen = false
        // Ends an edit without changes (so the list is not locked on the
        // next opening), then no reloads while nobody looks at the list.
        model?.windowClosed()
        // Roger stays in the Dock while the settings window is open.
        presence.leave(.library)
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
