import SwiftUI

struct LibraryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel
    /// Called when the library folder or the extra folders change.
    let onScopeChange: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            Group {
                if model.sidebar == .unfinished {
                    LibraryUnfinishedListView()
                } else {
                    LibraryListView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            LibraryDetailView(model: model)
        }
        .navigationTitle("Roger Library")
        .searchable(
            text: searchBinding,
            placement: .toolbar,
            prompt: model.sidebar.usesFilters ? "Search titles and text" : "Search is off for Unfinished"
        )
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItemGroup {
                LibraryDateFilterMenu(model: model)
                    .disabled(!model.sidebar.usesFilters)
                LibrarySortMenu(model: model)
                    .disabled(!model.sidebar.usesFilters)
            }
        }
        .background {
            // Cmd-F focuses the search field. The default Find menu item is
            // not wired to `.searchable` in an AppKit-hosted window.
            Button("Find") { if model.sidebar.usesFilters { searchFocused = true } }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 900, minHeight: 520)
        .onChange(of: coordinator.appState.libraryRoot) { _, _ in onScopeChange() }
        .onChange(of: coordinator.appState.extraScanFolders) { _, _ in onScopeChange() }
        .onChange(of: coordinator.pendingMeetingSessions.isEmpty) { _, isEmpty in
            if isEmpty && model.sidebar == .unfinished { model.sidebar = .all }
        }
    }

    /// SwiftUI cannot disable a toolbar search field. While Unfinished is
    /// selected the field shows nothing and ignores input; the search of
    /// the other lists is kept for when the user goes back.
    private var searchBinding: Binding<String> {
        Binding(
            get: { model.sidebar.usesFilters ? model.searchText : "" },
            set: { if model.sidebar.usesFilters { model.searchText = $0 } }
        )
    }
}
