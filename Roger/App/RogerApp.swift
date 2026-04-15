import SwiftUI

@main
struct RogerApp: App {
    @State private var coordinator = AppCoordinator()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openSettings: { openWindow(id: "settings") })
                .environment(coordinator)
        } label: {
            Image(systemName: coordinator.appState.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window("Roger Settings", id: "settings") {
            SettingsView()
                .environment(coordinator)
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)
    }
}
