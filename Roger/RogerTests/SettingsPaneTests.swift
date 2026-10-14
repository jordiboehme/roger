import Foundation
import Testing
@testable import Roger

struct SettingsPaneTests {
    @Test func everyOldTabHasItsPane() {
        let expected: [String: SettingsPane] = [
            "general": .general,
            "model": .model,
            "presets": .presets,
            "permissions": .permissions,
            "microphone": .microphone,
            "aiProvider": .aiProvider,
            "fileTranscription": .files,
            "recordings": .library,
            "agents": .agents,
            "about": .about,
        ]
        for (old, pane) in expected {
            #expect(SettingsPane(storedValue: old) == pane, "old tab \(old)")
        }
    }

    @Test func everyPaneRoundTrips() {
        for pane in SettingsPane.allCases {
            #expect(SettingsPane(storedValue: pane.rawValue) == pane)
        }
    }

    @Test func unknownValuesAreNil() {
        #expect(SettingsPane(storedValue: "") == nil)
        #expect(SettingsPane(storedValue: "General") == nil)
        #expect(SettingsPane(storedValue: "fileTranscriptions") == nil)
    }

    @Test func sidebarFollowsTheSpec() {
        let groups = SettingsPane.SidebarGroup.allCases.map { group in
            (group.title, group.panes.map(\.title))
        }
        #expect(groups.map(\.0) == [nil, "Transcription", "Library", nil])
        #expect(groups.map(\.1) == [
            ["General", "Presets", "Microphone"],
            ["Model", "AI Provider", "Files"],
            ["Library & Meetings", "Agents"],
            ["Permissions", "About"],
        ])
    }

    @Test func titlesHaveNoDashes() {
        for pane in SettingsPane.allCases {
            #expect(!pane.title.contains("\u{2014}") && !pane.title.contains("\u{2013}"))
        }
    }
}

@MainActor
struct SettingsNavigationTests {
    /// In-memory stand-in for the defaults.
    @MainActor
    final class Store {
        var value: String?
        var memory: SettingsPaneMemory {
            SettingsPaneMemory(load: { self.value }, save: { self.value = $0 })
        }
    }

    @Test func startsOnGeneralWithoutAStoredPane() {
        let navigation = SettingsNavigation(memory: Store().memory)
        #expect(navigation.selection == .general)
    }

    @Test func startsOnTheStoredPane() {
        let store = Store()
        store.value = "recordings"
        #expect(SettingsNavigation(memory: store.memory).selection == .library)
        store.value = "nonsense"
        #expect(SettingsNavigation(memory: store.memory).selection == .general)
    }

    @Test func remembersTheLastPane() {
        let store = Store()
        let first = SettingsNavigation(memory: store.memory)
        first.selection = .microphone
        #expect(store.value == "microphone")
        #expect(SettingsNavigation(memory: store.memory).selection == .microphone)
    }

    @Test func selectingTheSamePaneWritesNothing() {
        let store = Store()
        let navigation = SettingsNavigation(memory: store.memory)
        navigation.selection = .general
        #expect(store.value == nil)
    }
}
