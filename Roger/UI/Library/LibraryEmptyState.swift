import SwiftUI

/// What an empty list says. A search or date filter explains itself first;
/// otherwise each kind gets a hint how to make its first entry.
struct LibraryEmptyState: Equatable {
    let title: String
    let message: String
    let systemImage: String
    /// The settings pane a button under the message opens, if any.
    let settingsButton: SettingsPane?

    /// `missingRoot` is the library folder when it does not exist; that
    /// comes before everything else.
    static func make(
        sidebar: LibrarySidebarSelection,
        searchText: String,
        dateFilter: LibraryDateFilter,
        missingRoot: URL? = nil
    ) -> LibraryEmptyState {
        if let missingRoot {
            return .init(title: "Library folder not found",
                         message: "Roger cannot find \(missingRoot.path). Connect the drive that holds it or choose another folder in Settings > Library & Meetings.",
                         systemImage: "folder.badge.questionmark", settingsButton: .library)
        }
        if !searchText.isEmpty {
            return .init(title: "No Results", message: "Nothing matches \"\(searchText)\".",
                         systemImage: "magnifyingglass", settingsButton: nil)
        }
        if dateFilter != .any {
            return .init(title: "Nothing in This Time Span", message: "Try a wider date filter.",
                         systemImage: "calendar", settingsButton: nil)
        }
        switch sidebar {
        case .kind(.log):
            return .init(title: "No Log Entries",
                         message: "No log entries yet. Bind the Log preset to Option + Caps Lock in Settings > Presets.",
                         systemImage: "book.closed", settingsButton: .presets)
        case .kind(.meeting):
            return .init(title: "No Meetings", message: "No meetings yet. Start a recording from the menu bar.",
                         systemImage: "person.2", settingsButton: nil)
        case .kind(.transcript):
            return .init(title: "No Transcripts",
                         message: "No transcripts yet. Drop an audio or video file on the menu bar icon.",
                         systemImage: "doc.text", settingsButton: nil)
        case .all, .unfinished:
            return .init(title: "Nothing Here Yet",
                         message: "Save a log entry, record a meeting or drop a file on the menu bar icon.",
                         systemImage: "books.vertical", settingsButton: nil)
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
            if let pane = state.settingsButton {
                Button(pane == .presets ? "Open Presets Settings" : "Open Settings") {
                    coordinator.openSettings(pane)
                }
            }
        }
    }
}
