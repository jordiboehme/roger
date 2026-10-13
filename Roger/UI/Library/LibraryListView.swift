import SwiftUI

/// The middle column: items grouped by day (date sorts) with sticky
/// headers, multi-selection with Cmd and Shift.
struct LibraryListView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                if section.title.isEmpty {
                    rows(section.items)
                } else {
                    Section(section.title) {
                        rows(section.items)
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(model.isEditing)
        .overlay { overlay }
    }

    private func rows(_ items: [LibraryItem]) -> some View {
        ForEach(items) { item in
            LibraryItemRow(item: item, showsDate: !model.sort.isByDate)
                .tag(item.id)
        }
    }

    @ViewBuilder private var overlay: some View {
        if model.isLoading {
            ProgressView("Reading the library")
        } else if model.results.isEmpty {
            LibraryEmptyStateView(state: LibraryEmptyState.make(
                sidebar: model.sidebar,
                searchText: model.appliedSearch,
                dateFilter: model.dateFilter
            ))
        }
    }
}

/// Type icon, title, first line, time, duration and markers for audio,
/// screenshots and speakers.
struct LibraryItemRow: View {
    let item: LibraryItem
    /// Title and duration sorts have no day headers, so rows show the date.
    let showsDate: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(item.isUnfinished ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !item.firstLine.isEmpty {
                    Text(item.firstLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(showsDate
                         ? "\(LibraryFormat.longDate(item.date)) \(LibraryFormat.time(item.date))"
                         : LibraryFormat.time(item.date))
                    if let seconds = item.durationSeconds {
                        Text(LibraryFormat.duration(seconds))
                    }
                    if item.hasAudio {
                        Image(systemName: "waveform").help("Has audio")
                    }
                    if item.screenshotCount > 0 {
                        Label("\(item.screenshotCount)", systemImage: "photo").help("Screenshots")
                    }
                    if let speakers = item.speakerCount, speakers > 1 {
                        Label("\(speakers)", systemImage: "person.2").help("Speakers")
                    }
                    if item.isUnfinished {
                        Text("Unfinished").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }
}
