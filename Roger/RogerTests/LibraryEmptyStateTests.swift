import Foundation
import Testing
@testable import Roger

struct LibraryEmptyStateTests {
    @Test func searchComesFirst() {
        let state = LibraryEmptyState.make(sidebar: .kind(.log), searchText: "supplier", dateFilter: .today)
        #expect(state.title == "No Results")
        #expect(state.message == "Nothing matches \"supplier\".")
        #expect(state.settingsButton == nil)
    }

    @Test func dateFilterComesNext() {
        let state = LibraryEmptyState.make(sidebar: .all, searchText: "", dateFilter: .last7Days)
        #expect(state.title == "Nothing in This Time Span")
    }

    @Test func emptyLogsPointToThePresets() {
        let state = LibraryEmptyState.make(sidebar: .kind(.log), searchText: "", dateFilter: .any)
        #expect(state.title == "No Log Entries")
        #expect(state.message == "No log entries yet. Bind the Log preset to Caps+⌥ in Settings → Presets.")
        #expect(state.settingsButton == .presets)
    }

    @Test func otherKindsHaveHints() {
        #expect(LibraryEmptyState.make(sidebar: .kind(.meeting), searchText: "", dateFilter: .any).message
            == "No meetings yet. Start a recording from the menu bar.")
        #expect(LibraryEmptyState.make(sidebar: .kind(.transcript), searchText: "", dateFilter: .any).message
            == "No transcripts yet. Drop an audio or video file on the menu bar icon.")
        #expect(LibraryEmptyState.make(sidebar: .all, searchText: "", dateFilter: .any).message
            == "Save a log entry, record a meeting or drop a file on the menu bar icon.")
    }

    @Test func aMissingLibraryFolderComesFirst() {
        let state = LibraryEmptyState.make(
            sidebar: .kind(.log), searchText: "supplier", dateFilter: .today,
            missingRoot: URL(fileURLWithPath: "/Volumes/Drive/Roger")
        )
        #expect(state.title == "Library folder not found")
        #expect(state.message == "Roger cannot find /Volumes/Drive/Roger. Connect the drive that holds it or choose another folder in Settings > Library & Meetings.")
        #expect(state.settingsButton == .library)
    }
}
