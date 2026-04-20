import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor
let sharedCoordinator = AppCoordinator()

private let appLogger = Logger(subsystem: "com.jordiboehme.roger", category: "App")

@main
struct RogerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(sharedCoordinator)
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var dropView: StatusBarDropView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = sharedCoordinator

        installStatusItem(coordinator: coordinator)

        // Check permissions
        coordinator.permissionManager.checkPermissions()

        // Warm up the audio HAL so the first Caps Lock press captures reliably
        Task { await coordinator.warmUpMicrophone() }

        // Sync launch-at-login state with SMAppService (catches external changes)
        coordinator.appState.syncLaunchAtLogin()

        // Start model download
        Task {
            if !coordinator.transcriptionEngine.isReady {
                await coordinator.setupModel()
            }
        }

        // Start hotkey listener
        coordinator.startHotkey()

        // Show onboarding on first launch
        if !coordinator.appState.hasCompletedOnboarding {
            showOnboarding(coordinator: coordinator)
        }
    }

    // MARK: - Status Item

    private func installStatusItem(coordinator: AppCoordinator) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            appLogger.error("NSStatusItem.button is nil — menu bar icon will not appear")
            return
        }

        refreshIcon(on: button, coordinator: coordinator)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environment(coordinator)
        )

        self.statusItem = item
        self.popover = popover

        // Install a transparent `StatusBarDropView` on top of the status-item
        // button. Registering drag types on the button's backing window is
        // unreliable on macOS 26 / LSUIElement apps; a dedicated
        // NSDraggingDestination subview is the robust pattern. `hitTest`
        // returns nil so mouse clicks fall through to the button below.
        let drop = StatusBarDropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.isAcceptable = { [weak self] url in
            self?.isTranscribable(url) ?? false
        }
        drop.onDrop = { [weak self] url in
            self?.handleDrop(url: url)
        }
        button.addSubview(drop)
        self.dropView = drop

        observeMenuBarIcon(coordinator: coordinator)
    }

    fileprivate func handleDrop(url: URL) {
        sharedCoordinator.handleDroppedMediaFile(url: url)
    }

    /// Re-registers an `@Observable` tracker each time `menuBarIcon` changes so
    /// the status-item image stays in sync with dictation state. Trailing
    /// recursion is cheap — it only re-fires when the icon actually changes.
    private func observeMenuBarIcon(coordinator: AppCoordinator) {
        withObservationTracking { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            self.refreshIcon(on: button, coordinator: coordinator)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeMenuBarIcon(coordinator: coordinator)
            }
        }
    }

    private func refreshIcon(on button: NSStatusBarButton, coordinator: AppCoordinator) {
        let name = coordinator.appState.menuBarIcon
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Roger")
        image?.isTemplate = true
        button.image = image
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// Public so `AppCoordinator` can open the popover (e.g. after a background
    /// task completes, though today this is unused since file transcripts write
    /// to disk directly).
    func showPopover() {
        guard let popover, let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Drag & Drop

    fileprivate func isTranscribable(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) else {
            return false
        }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    // MARK: - Onboarding

    private func showOnboarding(coordinator: AppCoordinator) {
        let view = OnboardingView(onComplete: { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        .environment(coordinator)

        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Roger"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false

        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Transparent overlay hosted as a subview of the status-item button. Receives
/// drag-and-drop events directly (via `registerForDraggedTypes`) because the
/// `NSStatusItem.button.window` delegate pattern is unreliable on macOS 26 /
/// LSUIElement apps. `hitTest` returns nil so mouse clicks fall through to the
/// button beneath for the regular popover-toggle behaviour.
final class StatusBarDropView: NSView {
    var isAcceptable: (URL) -> Bool = { _ in false }
    var onDrop: (URL) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Pass all mouse events through to the real button below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptableURL(from: sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptableURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = acceptableURL(from: sender) else { return false }
        onDrop(url)
        return true
    }

    private func acceptableURL(from sender: any NSDraggingInfo) -> URL? {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: isAcceptable)
    }
}
