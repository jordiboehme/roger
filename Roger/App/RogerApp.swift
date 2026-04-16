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
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }

        let view = OnboardingView(onComplete: { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        .environment(sharedCoordinator)

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
