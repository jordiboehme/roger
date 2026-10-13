import SwiftUI

struct LibraryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel
    /// Called when the library folder or the extra folders change.
    let onScopeChange: () -> Void

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            Group {
                if model.sidebar == .unfinished {
                    LibraryUnfinishedListView()
                } else {
                    List(model.results, selection: $model.selection) { item in
                        Text(item.title).lineLimit(1)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            .overlay {
                if model.isLoading {
                    ProgressView("Reading the library")
                }
            }
        } detail: {
            Text(model.selection.isEmpty ? "No selection" : "\(model.selection.count) selected")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Roger Library")
        .frame(minWidth: 900, minHeight: 520)
        .onChange(of: coordinator.appState.libraryRoot) { _, _ in onScopeChange() }
        .onChange(of: coordinator.appState.extraScanFolders) { _, _ in onScopeChange() }
        .onChange(of: coordinator.pendingMeetingSessions.isEmpty) { _, isEmpty in
            if isEmpty && model.sidebar == .unfinished { model.sidebar = .all }
        }
    }
}
