import AppKit
import SwiftUI

/// Owns the settings window: an NSWindow hosting the settings sidebar and
/// panes, created once and reused. While it is open, Roger shows in the
/// Dock and in Cmd-Tab (through `AppWindowPresence`).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let frameName = "RogerSettingsWindow"
    static let defaultSize = NSSize(width: 720, height: 540)
    static let minimumSize = NSSize(width: 640, height: 460)

    let navigation: SettingsNavigation
    private let presence: AppWindowPresence
    private let frameAutosaveName: String?
    private let present: @MainActor (NSWindow) -> Void
    private let makeContent: @MainActor (SettingsNavigation) -> AnyView
    private(set) var window: NSWindow?
    /// True from `show` until the window closes (also while minimized).
    private(set) var isOpen = false

    /// `frameAutosaveName` nil keeps no frame and no restorable state
    /// (tests, snapshot runs).
    /// `present` puts the window on screen; tests pass a no-op.
    init(
        presence: AppWindowPresence,
        memory: SettingsPaneMemory,
        frameAutosaveName: String? = SettingsWindowController.frameName,
        present: @escaping @MainActor (NSWindow) -> Void = SettingsWindowController.presentOnScreen,
        makeContent: @escaping @MainActor (SettingsNavigation) -> AnyView
    ) {
        self.navigation = SettingsNavigation(memory: memory)
        self.presence = presence
        self.frameAutosaveName = frameAutosaveName
        self.present = present
        self.makeContent = makeContent
    }

    /// Shows the window with `pane` selected (the last pane when nil). A
    /// second call brings the same window to the front.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        let window = self.window ?? makeWindow()
        isOpen = true
        // Before the window is shown, so the Dock icon does not flash.
        presence.enter(.settings)
        if window.isMiniaturized { window.deminiaturize(nil) }
        present(window)
        widenSidebarOnce()
    }

    private var sidebarWidened = false

    /// SwiftUI starts the sidebar narrower than its column width in an
    /// AppKit window, which cuts "Library & Meetings". Set it once after the
    /// first layout; the user can still drag it.
    private func widenSidebarOnce() {
        guard !sidebarWidened, let content = window?.contentView else { return }
        DispatchQueue.main.async {
            guard let split = Self.firstSplitView(in: content), split.arrangedSubviews.count > 1,
                  split.arrangedSubviews[0].frame.width < Self.sidebarWidth else { return }
            split.setPosition(Self.sidebarWidth, ofDividerAt: 0)
            self.sidebarWidened = true
        }
    }

    static let sidebarWidth: CGFloat = 200

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = firstSplitView(in: child) { return split }
        }
        return nil
    }

    static func presentOnScreen(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        // Right after the policy change the menu bar can still belong to the
        // previous app. Activating on the next run loop turn fixes that.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        isOpen = false
        presence.leave(.settings)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeContent(navigation))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // Keep the saved frame; do not let SwiftUI resize the window.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.title = navigation.selection.title
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.delegate = self
        window.contentMinSize = Self.minimumSize
        if frameAutosaveName == nil { window.isRestorable = false }
        if let name = frameAutosaveName, window.setFrameUsingName(name) {
            window.setFrameAutosaveName(name)
        } else {
            window.setContentSize(Self.defaultSize)
            window.center()
            if let name = frameAutosaveName { window.setFrameAutosaveName(name) }
        }
        self.window = window
        return window
    }
}
