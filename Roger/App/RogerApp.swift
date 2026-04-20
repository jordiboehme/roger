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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var onboardingWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

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

        // Wire drag-drop on the button's backing window. Menu-bar drops land
        // on Roger for transcription-from-file.
        if let window = button.window {
            window.registerForDraggedTypes([.fileURL])
            window.delegate = self
        }

        observeMenuBarIcon(coordinator: coordinator)
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

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptableURL(from: sender) != nil ? .copy : []
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptableURL(from: sender) != nil ? .copy : []
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = acceptableURL(from: sender) else { return false }
        sharedCoordinator.handleDroppedMediaFile(url: url)
        return true
    }

    /// Fallback for OpenRadar #1745403 — drops originating from Dock stack
    /// popovers skip `performDragOperation`. If the drop ended inside the
    /// status-item button frame and the pasteboard still has a usable URL,
    /// run the same handler. `draggingLocation` is in window coords.
    func draggingEnded(_ sender: any NSDraggingInfo) {
        guard let button = statusItem?.button else { return }
        let buttonPoint = button.convert(sender.draggingLocation, from: nil)
        guard button.bounds.contains(buttonPoint) else { return }
        if let url = acceptableURL(from: sender) {
            sharedCoordinator.handleDroppedMediaFile(url: url)
        }
    }

    private func acceptableURL(from sender: any NSDraggingInfo) -> URL? {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first { isTranscribable($0) }
    }

    private func isTranscribable(_ url: URL) -> Bool {
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
