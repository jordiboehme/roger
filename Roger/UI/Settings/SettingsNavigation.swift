import Foundation
import Observation

/// Where the last settings pane is kept between launches.
struct SettingsPaneMemory {
    static let key = "settingsLastPane"

    let load: @MainActor () -> String?
    let save: @MainActor (String) -> Void

    /// The app's own defaults.
    static var standard: SettingsPaneMemory {
        SettingsPaneMemory(
            load: { UserDefaults.standard.string(forKey: key) },
            save: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    /// Remembers nothing (snapshot runs).
    static var none: SettingsPaneMemory {
        SettingsPaneMemory(load: { nil }, save: { _ in })
    }
}

/// The selected pane of the settings window. Shared by the window
/// controller, the sidebar and panes that link to another pane.
@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsPane {
        didSet {
            if selection != oldValue { memory.save(selection.rawValue) }
        }
    }

    @ObservationIgnored private let memory: SettingsPaneMemory

    init(memory: SettingsPaneMemory) {
        self.memory = memory
        self.selection = memory.load().flatMap(SettingsPane.init(storedValue:)) ?? .general
    }
}
