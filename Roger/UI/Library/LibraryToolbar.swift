import SwiftUI

struct LibraryDateFilterMenu: View {
    @Bindable var model: LibraryModel
    @State private var showsCustomRange = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        Menu {
            Picker("Date", selection: $model.dateFilter) {
                Text("Any Date").tag(LibraryDateFilter.any)
                Text("Today").tag(LibraryDateFilter.today)
                Text("Last 7 Days").tag(LibraryDateFilter.last7Days)
                Text("Last 30 Days").tag(LibraryDateFilter.last30Days)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Custom Range…") { showsCustomRange = true }
        } label: {
            Label(model.dateFilter.label, systemImage: "calendar")
        }
        .help("Filter by date")
        .popover(isPresented: $showsCustomRange) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Cancel") { showsCustomRange = false }
                    Button("Apply") {
                        model.dateFilter = .custom(from: from, to: to)
                        showsCustomRange = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 280)
        }
    }
}

struct LibrarySortMenu: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort")
    }
}
