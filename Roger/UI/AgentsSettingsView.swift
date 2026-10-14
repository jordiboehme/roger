import AppKit
import SwiftUI

/// Settings > Agents: what agents need to read Roger's library.
struct AgentsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var status: AgentsLibraryStatus?
    @State private var consumerAction: ConsumerAction?
    @State private var actionError: String?

    enum ConsumerAction: Identifiable, Equatable {
        case startOver(String)
        case forget(String)

        var id: String {
            switch self {
            case .startOver(let name): return "start-over-" + name
            case .forget(let name): return "forget-" + name
            }
        }

        var name: String {
            switch self {
            case .startOver(let name), .forget(let name): return name
            }
        }
    }

    static let documentsHint = "The first time an agent reads the library, macOS may ask whether Terminal (or the app that runs the agent) may access your Documents folder. Allow it, or Roger's tools cannot read the library. You can change this later in System Settings > Privacy & Security > Files and Folders."

    private var root: URL { coordinator.appState.libraryLayout.root }

    private var executableChoice: RogerMCPLocation.Choice {
        RogerMCPLocation.choose(appBundle: Bundle.main.bundleURL)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                libraryCard
                manualSetupCard
                consumersCard
                Text(Self.documentsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .task { reload() }
        .confirmationDialog(
            consumerAction.map(confirmationTitle) ?? "",
            isPresented: Binding(get: { consumerAction != nil }, set: { if !$0 { consumerAction = nil } }),
            presenting: consumerAction
        ) { action in
            Button(confirmationButton(action), role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmationMessage(action))
        }
        .alert("Could not change the consumer", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Cards

    private var libraryCard: some View {
        settingsCard(icon: "books.vertical", title: "Library") {
            Text(root.path)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            if let status, status.isSetUp {
                if let last = status.lastEventAt {
                    Text("\(status.eventCount) changes recorded, the last one \(last.formatted(.relative(presentation: .named))).")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No changes recorded yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The change list is not set up yet. Roger sets it up when it starts.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var manualSetupCard: some View {
        settingsCard(icon: "wrench.and.screwdriver", title: "Manual setup") {
            DisclosureGroup("Commands to add Roger to an agent yourself") {
                VStack(alignment: .leading, spacing: 10) {
                    switch executableChoice {
                    case .usable(let executable):
                        Text("Claude Code:")
                        copyableBlock(McpCommandFormatter.claudeAdd(executable: executable))
                        Text("Other clients (.mcp.json, Cursor, Copilot CLI, Kiro):")
                        copyableBlock(McpCommandFormatter.jsonSnippet(executable: executable))
                    case .unusable(let reason):
                        Text(reason).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private var consumersCard: some View {
        settingsCard(icon: "person.2.badge.gearshape", title: "Consumers") {
            let consumers = status?.consumers ?? []
            if consumers.isEmpty {
                Text("No agent has read the library yet. Each agent keeps a bookmark here under its consumer name.")
                    .foregroundStyle(.secondary)
            }
            ForEach(consumers) { consumer in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(consumer.name).font(.body.weight(.medium))
                        Text("At change \(consumer.seq), \(consumer.openEvents) open, \(consumer.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start Over") { consumerAction = .startOver(consumer.name) }
                    Button("Forget") { consumerAction = .forget(consumer.name) }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        let root = self.root
        Task {
            let fresh = await Task.detached { AgentsLibraryStatus.read(root: root) }.value
            status = fresh
        }
    }

    private func perform(_ action: ConsumerAction) {
        let bookmarks = ConsumerBookmarks(root: root)
        do {
            switch action {
            case .startOver(let name): try bookmarks.reset(name)
            case .forget(let name): try bookmarks.forget(name)
            }
        } catch {
            actionError = error.localizedDescription
        }
        reload()
    }

    private func confirmationTitle(_ action: ConsumerAction) -> String {
        switch action {
        case .startOver(let name): return "Start over for \(name)?"
        case .forget(let name): return "Forget \(name)?"
        }
    }

    private func confirmationButton(_ action: ConsumerAction) -> String {
        switch action {
        case .startOver: return "Start Over"
        case .forget: return "Forget"
        }
    }

    private func confirmationMessage(_ action: ConsumerAction) -> String {
        switch action {
        case .startOver:
            return "The next time \(action.name) asks for changes, it gets the whole library again."
        case .forget:
            return "Roger deletes the bookmark of \(action.name). If it asks again, it starts with the whole library."
        }
    }

    // MARK: - Helpers

    private func copyableBlock(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func settingsCard(icon: String, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
