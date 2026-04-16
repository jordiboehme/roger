import SwiftUI

@MainActor
let sharedCoordinator = AppCoordinator()

@main
struct RogerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(sharedCoordinator)
        } label: {
            Image(systemName: sharedCoordinator.appState.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(sharedCoordinator)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = sharedCoordinator

        // Check permissions
        coordinator.permissionManager.checkPermissions()

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
