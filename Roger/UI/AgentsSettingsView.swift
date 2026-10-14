import AppKit
import SwiftUI

/// Settings > Agents: what agents need to read Roger's library.
struct AgentsSettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var status: AgentsLibraryStatus?
    @State private var consumerAction: ConsumerAction?
    @State private var actionError: String?
    /// Built once in `.task`, not on every view init.
    @State private var agents: AgentsController?
    @State private var agentsLoaded = false
    @State private var confirmUninstall: HarnessID?

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
                harnessesCard
                desktopCard
                manualSetupCard
                consumersCard
                Text(Self.documentsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .task {
            reload()
            if !agentsLoaded {
                agents = AgentsController.live()
                agentsLoaded = true
            }
            await agents?.refresh()
            await agents?.refreshDesktop()
        }
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
        .confirmationDialog(
            "Move your changed skill to the Trash?",
            isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }),
            presenting: confirmUninstall
        ) { id in
            Button("Move to Trash", role: .destructive) {
                Task {
                    _ = await agents?.uninstall(id, confirmChanged: true)
                    coordinator.checkAgentSkills()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You changed this skill after Roger installed it. Roger moves it to the Trash, so you can still get it back.")
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

    private var harnessesCard: some View {
        settingsCard(icon: "terminal", title: "Coding agents") {
            if let agents {
                if case .unusable(let reason) = agents.executableChoice {
                    Text(reason).foregroundStyle(.orange)
                }
                if agents.rows.isEmpty {
                    Text("No coding agent found. Roger looks for Claude Code, Codex, Gemini CLI, Cursor, Copilot CLI and Kiro in your home folder.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agents.rows) { row in
                    harnessRow(row, agents: agents)
                    if row.id != agents.rows.last?.id { Divider() }
                }
            } else if agentsLoaded {
                Text("This copy of Roger has no ingest skill.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var desktopCard: some View {
        if let agents, agents.desktopAvailable {
            settingsCard(icon: "macwindow", title: "Claude Desktop") {
                if agents.desktopAppMoved() {
                    Text("Roger.app moved - add again.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Add to Claude Desktop") {
                        Task { await agents.addToClaudeDesktop() }
                    }
                    .disabled(agents.desktopBusy)
                    Button("Save Skill for Claude Desktop") {
                        Task { await agents.saveSkillForClaudeDesktop() }
                    }
                    .disabled(agents.desktopBusy)
                }
                if let added = agents.desktopRecord.extensionAddedAt {
                    Text("Extension last added \(added.formatted(.relative(presentation: .named))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let saved = agents.desktopRecord.skillSavedAt {
                    Text("Skill last saved \(saved.formatted(.relative(presentation: .named))).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = agents.desktopMessage {
                    Text(message).font(.caption)
                }
                Text("Roger cannot see what Claude Desktop has installed. These lines show what Roger did last.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func harnessRow(_ row: AgentsController.Row, agents: AgentsController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.spec.name).font(.body.weight(.medium))
                    Text(skillText(row) + " · " + serverText(row.connection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    if let label = row.primaryAction {
                        Button(label) {
                            Task {
                                await agents.install(row.id)
                                coordinator.checkAgentSkills()
                            }
                        }
                    }
                    if row.canUninstall {
                        Button("Uninstall") {
                            Task {
                                if await agents.uninstall(row.id, confirmChanged: false) == false {
                                    confirmUninstall = row.id
                                }
                                coordinator.checkAgentSkills()
                            }
                        }
                    }
                }
            }
            if let message = row.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            if let command = row.manualCommand {
                copyableBlock(command)
            }
        }
    }

    private func skillText(_ row: AgentsController.Row) -> String {
        if let cover = row.coveredBy {
            return "Skill covered by \(HarnessCatalog.spec(cover).name)"
        }
        switch row.skillState {
        case .notInstalled: return "Skill not installed"
        case .upToDate: return "Skill up to date"
        case .outdated: return "Skill outdated"
        case .changedByYou: return "Skill changed by you"
        }
    }

    private func serverText(_ connection: ServerConnection) -> String {
        switch connection {
        case .connected: return "Server connected"
        case .otherCommand: return "Server points to another roger-mcp"
        case .notConnected: return "Server not connected"
        case .unknown: return "Server state unknown"
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
