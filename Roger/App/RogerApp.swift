import AppKit
import KeyboardShortcuts
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

extension KeyboardShortcuts.Name {
    /// Global hotkey to start/stop a meeting recording. User-configurable
    /// from the Recordings settings tab. Unset by default — Roger only takes
    /// the hotkey if the user explicitly assigns one.
    static let meetingRecordingToggle = Self("meetingRecordingToggle")
}

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
    /// Drives the per-second refresh of the status-item title while a meeting
    /// recording is live AND the floating overlay is hidden — that's the
    /// only state where the menu-bar timestamp matters. Nil otherwise.
    private var meetingTickTimer: DispatchSourceTimer?

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

        // Wire the meeting-recording global hotkey. Only fires when the
        // user has assigned a key combo from the Recordings settings tab.
        KeyboardShortcuts.onKeyDown(for: .meetingRecordingToggle) {
            Task { @MainActor in
                await sharedCoordinator.toggleMeetingRecording()
            }
        }

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
        // Meeting-recording mode wins over dictation in icon priority. While
        // capture is live we use the universal "rec" glyph so the menu bar
        // signals the higher-stakes state.
        let isRecordingMeeting: Bool
        let meetingStartedAt: Date?
        switch coordinator.meetingRecorder.state {
        case .recording(let at):
            isRecordingMeeting = true
            meetingStartedAt = at
        default:
            isRecordingMeeting = false
            meetingStartedAt = nil
        }

        let symbol: String
        if isRecordingMeeting {
            symbol = "record.circle.fill"
        } else {
            symbol = coordinator.appState.menuBarIcon
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Roger")
        image?.isTemplate = true
        button.image = image

        // The elapsed-time chip in the menu bar appears only when the user
        // has hidden the floating overlay — otherwise the panel itself is
        // their indicator. Clearing the title also reverts the icon position
        // so non-meeting states render unchanged.
        if isRecordingMeeting, coordinator.meetingOverlayHidden, let startedAt = meetingStartedAt {
            button.imagePosition = .imageLeading
            button.title = " " + formatMeetingElapsed(Date().timeIntervalSince(startedAt))
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }

        updateMeetingTickTimer(coordinator: coordinator)
    }

    /// Installs (or tears down) the 1 Hz timer that refreshes the menu-bar
    /// timestamp. Only runs while recording is live AND the overlay is
    /// hidden — at most one timer at a time.
    private func updateMeetingTickTimer(coordinator: AppCoordinator) {
        let needsTimer: Bool
        switch coordinator.meetingRecorder.state {
        case .recording: needsTimer = coordinator.meetingOverlayHidden
        default: needsTimer = false
        }

        if needsTimer && meetingTickTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.refreshIcon(on: button, coordinator: coordinator)
            }
            timer.resume()
            meetingTickTimer = timer
        } else if !needsTimer, let timer = meetingTickTimer {
            timer.cancel()
            meetingTickTimer = nil
        }
    }

    private func formatMeetingElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
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
