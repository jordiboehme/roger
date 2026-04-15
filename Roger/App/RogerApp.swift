import SwiftUI

@main
struct RogerApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra("Roger", systemImage: "waveform") {
            MenuBarView()
                .environment(coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(coordinator)
        }
    }
}
