import SwiftUI

/// What an empty list says. A search or date filter explains itself first;
/// otherwise each kind gets a hint how to make its first entry.
struct LibraryEmptyState: Equatable {
    let title: String
    let message: String
    let systemImage: String
    let showsPresetsButton: Bool

    static func make(sidebar: LibrarySidebarSelection, searchText: String, dateFilter: LibraryDateFilter) -> LibraryEmptyState {
        if !searchText.isEmpty {
            return .init(title: "No Results", message: "Nothing matches \"\(searchText)\".",
                         systemImage: "magnifyingglass", showsPresetsButton: false)
        }
        if dateFilter != .any {
            return .init(title: "Nothing in This Time Span", message: "Try a wider date filter.",
                         systemImage: "calendar", showsPresetsButton: false)
        }
        switch sidebar {
        case .kind(.log):
            return .init(title: "No Log Entries",
                         message: "No log entries yet. Bind the Log preset to Caps+⌥ in Settings → Presets.",
                         systemImage: "book.closed", showsPresetsButton: true)
        case .kind(.meeting):
            return .init(title: "No Meetings", message: "No meetings yet. Start a recording from the menu bar.",
                         systemImage: "person.2", showsPresetsButton: false)
        case .kind(.transcript):
            return .init(title: "No Transcripts",
                         message: "No transcripts yet. Drop an audio or video file on the menu bar icon.",
                         systemImage: "doc.text", showsPresetsButton: false)
        case .all, .unfinished:
            return .init(title: "Nothing Here Yet",
                         message: "Save a log entry, record a meeting or drop a file on the menu bar icon.",
                         systemImage: "books.vertical", showsPresetsButton: false)
        }
    }
}

struct LibraryEmptyStateView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let state: LibraryEmptyState

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.systemImage)
        } description: {
            Text(state.message)
        } actions: {
            if state.showsPresetsButton {
                SettingsLink {
                    Text("Open Presets Settings")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    coordinator.appState.pendingSettingsTab = .presets
                })
            }
        }
    }
}
