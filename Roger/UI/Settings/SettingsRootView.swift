import SwiftUI

/// The settings window: sidebar grouped like System Settings, the selected
/// pane on the right. The window title is the pane name.
struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SettingsPane.SidebarGroup.allCases, id: \.self) { group in
                    if let title = group.title {
                        Section(title) { rows(group.panes) }
                    } else {
                        Section { rows(group.panes) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsWhileVisible(navigation: navigation) {
                SettingsPaneContent(pane: navigation.selection)
            }
            .navigationTitle(navigation.selection.title)
        }
        .environment(navigation)
    }

    /// List selection is optional; a click on empty space keeps the pane.
    private var sidebarSelection: Binding<SettingsPane?> {
        Binding(
            get: { navigation.selection },
            set: { if let pane = $0 { navigation.selection = pane } }
        )
    }

    private func rows(_ panes: [SettingsPane]) -> some View {
        ForEach(panes) { pane in
            Label {
                Text(pane.title)
            } icon: {
                SettingsPaneIcon(pane: pane)
            }
            .tag(pane)
        }
    }
}

/// Shows its content only while the settings window is open, so a closed
/// window ends the pane and a reopened one starts it again.
struct SettingsWhileVisible<Content: View>: View {
    let navigation: SettingsNavigation
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if navigation.isVisible { content() }
        }
    }
}

/// White symbol on a small rounded colored square, like System Settings.
struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .imageScale(.small)
            .frame(width: 20, height: 20)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The pane for a sidebar entry.
struct SettingsPaneContent: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .presets: PresetsPane()
        case .microphone: MicrophonePane()
        case .model: ModelPane()
        case .aiProvider: AIProviderPane()
        case .files: FilesPane()
        case .library: LibraryPane()
        case .agents: AgentsPane()
        case .commands: CommandsPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}
