import SwiftUI

struct LibrarySidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: Binding(
            get: { Optional(model.sidebar) },
            set: { if let value = $0 { model.sidebar = value } }
        )) {
            Section("Library") {
                row(.all, title: "All", systemImage: "tray.full", count: model.totalCount)
                ForEach(LibraryItemKind.allCases, id: \.self) { kind in
                    row(.kind(kind), title: kind.pluralName, systemImage: kind.systemImage, count: model.counts[kind] ?? 0)
                }
            }
            if !coordinator.pendingMeetingSessions.isEmpty {
                Section("Needs Attention") {
                    row(.unfinished, title: "Unfinished", systemImage: "exclamationmark.triangle",
                        count: coordinator.pendingMeetingSessions.count)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ selection: LibrarySidebarSelection, title: String, systemImage: String, count: Int) -> some View {
        Label(title, systemImage: systemImage)
            .badge(count)
            .tag(selection)
    }
}
