import AppKit
import SwiftUI

/// Settings > Agents: what agents need to read Roger's library.
struct AgentsPane: View {
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

    /// Looked up once, off the main actor, by `AgentsController.live()`.
    private var executableChoice: RogerMCPLocation.Choice? { agents?.executableChoice }

    var body: some View {
        SettingsForm {
            librarySection
            harnessesSection
            desktopSection
            manualSetupSection
            consumersSection
        }
        .task {
            reload()
            if !agentsLoaded {
                agents = await AgentsController.live()
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

    // MARK: - Sections

    private var librarySection: some View {
        Section("Library") {
            VStack(alignment: .leading, spacing: 4) {
                Text(root.path)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                Group {
                    if let status, status.isSetUp {
                        if let last = status.lastEventAt {
                            Text("\(status.eventCount) changes recorded, the last one \(SettingsFormat.relative(last)).")
                        } else {
                            Text("No changes recorded yet.")
                        }
                    } else {
                        Text("The change list is not set up yet. Roger sets it up when it starts.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var harnessesSection: some View {
        Section("Coding agents") {
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
                }
            } else if agentsLoaded {
                Text("This copy of Roger has no ingest skill.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var desktopSection: some View {
        if let agents, agents.desktopAvailable {
            Section {
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
                    Text("Extension last added \(SettingsFormat.relative(added)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let saved = agents.desktopRecord.skillSavedAt {
                    Text("Skill last saved \(SettingsFormat.relative(saved)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let message = agents.desktopMessage {
                    Text(message)
                }
            } header: {
                Text("Claude Desktop")
            } footer: {
                Text("Roger cannot see what Claude Desktop has installed. These lines show what Roger did last.")
            }
        }
    }

    private func harnessRow(_ row: AgentsController.Row, agents: AgentsController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.spec.name)
                    Text(skillText(row) + " · " + serverText(row.connection))
                        .font(.subheadline)
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
                Text(message).font(.subheadline).foregroundStyle(.orange)
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

    private var manualSetupSection: some View {
        Section {
            DisclosureGroup("Manual setup") {
                VStack(alignment: .leading, spacing: 10) {
                    switch executableChoice {
                    case .usable(let executable)?:
                        Text("Claude Code:")
                        copyableBlock(McpCommandFormatter.claudeAdd(executable: executable))
                        Text("Other clients (.mcp.json, Cursor, Copilot CLI, Kiro):")
                        copyableBlock(McpCommandFormatter.jsonSnippet(executable: executable))
                    case .unusable(let reason)?:
                        Text(reason).foregroundStyle(.secondary)
                    case nil:
                        if agentsLoaded {
                            Text("Not available in this copy of Roger.").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(.top, 6)
            }
        } footer: {
            Text("Commands to add Roger to an agent yourself.")
        }
    }

    private var consumersSection: some View {
        Section {
            let consumers = status?.consumers ?? []
            if consumers.isEmpty {
                Text("No agent has read the library yet. Each agent keeps a bookmark here under its consumer name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(consumers) { consumer in
                SettingsRow(
                    title: consumer.name,
                    note: "At change \(consumer.seq), \(consumer.openEvents) open, \(SettingsFormat.relative(consumer.updatedAt))"
                ) {
                    HStack {
                        Button("Start Over") { consumerAction = .startOver(consumer.name) }
                        Button("Forget") { consumerAction = .forget(consumer.name) }
                    }
                }
            }
        } header: {
            Text("Consumers")
        } footer: {
            Text(Self.documentsHint)
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

    /// The bookmark files are written off the main actor.
    private func perform(_ action: ConsumerAction) {
        let bookmarks = ConsumerBookmarks(root: root)
        Task {
            do {
                try await Task.detached {
                    switch action {
                    case .startOver(let name): try bookmarks.reset(name)
                    case .forget(let name): try bookmarks.forget(name)
                    }
                }.value
            } catch {
                actionError = error.localizedDescription
            }
            reload()
        }
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
                .font(.callout.monospaced())
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
}
