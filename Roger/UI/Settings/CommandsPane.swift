import SwiftUI

/// Settings > Commands: the command list on the leading side, the selected
/// command on the trailing side. Built like the Presets pane.
struct CommandsPane: View {
    static let trustNote = "Commands run as you, with your login shell. Only add commands you trust."
    static let placeholderNote = "Placeholders: {prompt} in the command line. {file}, {key}, {title} and {kind} in both. In the command line, values are quoted for the shell."
    static let askNote = "Shows Allow and Not now before each run."

    /// "Roger looks for Claude Code, Codex, ... and Kiro on your search path."
    static var searchedAgentsNote: String {
        let names = HarnessCatalog.all.filter { $0.cli != nil }.map(\.name)
        return "Roger looks for \(names.joinedAsList) on your search path."
    }

    /// `~` for the home folder, so the setting reads the same on every Mac.
    static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedCommandID: UUID?
    @State private var pendingDelete: AgentCommand?
    /// The item "Run now" uses. Nil while the library is empty or not read yet.
    @State private var newestItem: CommandItemInfo?
    @State private var showingSuggestions = false

    var body: some View {
        HStack(spacing: 0) {
            commandList
                .frame(width: PresetsPane.listWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Also marks the failures as seen.
            coordinator.commandScheduler.isPaneVisible = true
            if selectedCommandID == nil {
                selectedCommandID = coordinator.appState.commands.first?.id
            }
        }
        .onDisappear {
            coordinator.commandScheduler.isPaneVisible = false
        }
        .task {
            newestItem = await coordinator.newestLibraryItemInfo()
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.displayName ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { command in
            Button("Delete", role: .destructive) { delete(command) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You cannot undo this.")
        }
    }

    // MARK: - List

    private var commandList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedCommandID) {
                ForEach(coordinator.appState.commands) { command in
                    CommandListRow(command: command, failed: coordinator.commandScheduler.lastRuns[command.id]?.hasFailed ?? false)
                        .tag(command.id)
                        .contextMenu {
                            Button("Duplicate") { duplicate(command) }
                            Button("Delete…", role: .destructive) { pendingDelete = command }
                        }
                }
            }
            Divider()
            HStack {
                Button {
                    addCommand()
                } label: {
                    Label("New Command", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New Command")
                Spacer(minLength: 8)
                Button("Suggest Commands") { showingSuggestions = true }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(8)
        }
        .sheet(isPresented: $showingSuggestions) {
            CommandSuggestionsSheet(load: { await coordinator.commandSuggestions() }, onAdd: add)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedCommandID, let command = coordinator.appState.command(id: id) {
            let lastRun = coordinator.commandScheduler.lastRuns[id]
            CommandDetailForm(
                command: binding(for: id, fallback: command),
                lastRun: lastRun,
                canRunNow: newestItem != nil && lastRun?.outcome != .running,
                libraryIsEmpty: newestItem == nil,
                onRunNow: { runNow(id) },
                onDelete: { pendingDelete = command }
            )
            .id(id)
        } else {
            ContentUnavailableView {
                Label(coordinator.appState.commands.isEmpty ? "No Commands" : "No Command Selected", systemImage: "terminal")
            } description: {
                Text("A command can run after Roger saved a log entry, meeting or file transcript. \(Self.trustNote)")
            } actions: {
                Button("New Command", action: addCommand)
            }
        }
    }

    /// Bound by id, not by index, so deleting a command never writes into
    /// another one.
    private func binding(for id: UUID, fallback: AgentCommand) -> Binding<AgentCommand> {
        Binding(
            get: { coordinator.appState.command(id: id) ?? fallback },
            set: { newValue in
                guard let index = coordinator.appState.commands.firstIndex(where: { $0.id == id }) else { return }
                coordinator.appState.commands[index] = newValue
            }
        )
    }

    // MARK: - Actions

    private func addCommand() {
        add(.blank())
    }

    private func add(_ command: AgentCommand) {
        coordinator.appState.commands.append(command)
        selectedCommandID = command.id
    }

    private func duplicate(_ command: AgentCommand) {
        var copy = command
        copy.id = UUID()
        copy.name = "\(command.name) Copy"
        coordinator.appState.commands.append(copy)
        selectedCommandID = copy.id
    }

    private func delete(_ command: AgentCommand) {
        coordinator.appState.commands.removeAll { $0.id == command.id }
        coordinator.commandScheduler.forget(command.id)
        if selectedCommandID == command.id {
            selectedCommandID = coordinator.appState.commands.first?.id
        }
    }

    /// Reads the library again, so a log saved a moment ago is the item.
    private func runNow(_ id: UUID) {
        Task {
            newestItem = await coordinator.newestLibraryItemInfo()
            guard let item = newestItem, let command = coordinator.appState.command(id: id) else { return }
            // The user just asked for it: no question.
            coordinator.commandScheduler.trigger(command, item: item, ask: false)
        }
    }
}

/// The list behind "Suggest Commands": one row per coding agent and mode.
private struct CommandSuggestionsSheet: View {
    let load: () async -> [CommandSuggestion]
    let onAdd: (AgentCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [CommandSuggestion]?

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 420)
        .task {
            suggestions = await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let suggestions {
            if suggestions.isEmpty {
                ContentUnavailableView {
                    Label("No Coding Agents Found", systemImage: "terminal")
                } description: {
                    Text(CommandsPane.searchedAgentsNote)
                }
            } else {
                SettingsForm {
                    Section {
                        ForEach(suggestions) { suggestion in
                            SettingsRow(title: suggestion.title, note: note(for: suggestion)) {
                                Button("Add") {
                                    onAdd(suggestion.command)
                                    dismiss()
                                }
                                .disabled(suggestion.disabledReason != nil)
                            }
                        }
                    } header: {
                        Text("Suggested commands")
                    } footer: {
                        Text("Each command reads what is new in Roger with the ingest-roger skill. You can change it after you add it.")
                    }
                }
            }
        } else {
            ProgressView("Looking for coding agents…")
        }
    }

    private func note(for suggestion: CommandSuggestion) -> String {
        if let reason = suggestion.disabledReason { return reason }
        return suggestion.usesCrystalline ? "Uses Crystalline" : "Plain summary"
    }
}

private extension CommandRunRecord {
    var hasFailed: Bool {
        if case .failed = outcome { return true }
        return false
    }
}

/// One row of the command list: name, and a mark for a failed last run.
private struct CommandListRow: View {
    let command: AgentCommand
    let failed: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(command.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(command.name)
            Spacer(minLength: 4)
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The last run failed")
            } else if command.mode == .interactive {
                Image(systemName: "macwindow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Runs in a terminal window")
            }
        }
        .contentShape(Rectangle())
    }
}

/// The selected command as a grouped form.
private struct CommandDetailForm: View {
    @Binding var command: AgentCommand
    let lastRun: CommandRunRecord?
    let canRunNow: Bool
    let libraryIsEmpty: Bool
    let onRunNow: () -> Void
    let onDelete: () -> Void
    @State private var showingFolderPicker = false

    /// The preview fills the placeholders with this made-up log entry.
    static let sampleItem = CommandItemInfo(
        file: "~/Documents/Roger/Logs/2026/10/2026-10-15 09-00-00.md",
        key: "log/2026/10/2026-10-15 09-00-00",
        title: "Log 2026-10-15 09:00 - Call Anna about the offer",
        kind: "log"
    )

    var body: some View {
        SettingsForm {
            Section("Command") {
                TextField("Name", text: $command.name, prompt: Text("Untitled"))
                    // A right-aligned field hides a trailing space while you type.
                    .multilineTextAlignment(.leading)
                // Label above, so a long line gets the full width.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command line")
                    TextField("Command line", text: $command.commandLine, prompt: Text("my-agent {prompt}"))
                        .labelsHidden()
                        .font(.body.monospaced())
                }
                SettingsTextEditor(title: "Prompt", text: $command.prompt)
                LabeledContent("Working directory") {
                    HStack {
                        TextField("Working directory", text: $command.workingDirectory, prompt: Text("~"))
                            .labelsHidden()
                        Button("Choose…") { showingFolderPicker = true }
                    }
                }
            }

            Section("How it runs") {
                Picker("Runs", selection: $command.mode) {
                    ForEach(CommandMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if command.mode == .interactive {
                    Picker("Terminal", selection: $command.terminal) {
                        ForEach(TerminalApp.allCases) { terminal in
                            Text(terminal.displayName).tag(terminal)
                        }
                    }
                } else {
                    Stepper(
                        "Timeout: \(command.timeoutMinutes) \(command.timeoutMinutes == 1 ? "minute" : "minutes")",
                        value: $command.timeoutMinutes,
                        in: 1...120
                    )
                }
                SettingsToggle(title: "Ask before running", note: CommandsPane.askNote, isOn: $command.askBeforeRunning)
            }

            Section {
                Text(preview)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Preview")
            } footer: {
                Text(CommandsPane.placeholderNote)
            }

            Section {
                SettingsRow(
                    title: "Run now",
                    note: libraryIsEmpty ? "Your library is empty." : "Runs the command for the newest item in your library\(command.askBeforeRunning ? " without asking" : "")."
                ) {
                    Button("Run Now", action: onRunNow)
                        .disabled(!canRunNow)
                }
                if let lastRun {
                    SettingsRow(title: statusTitle(lastRun), note: failureMessage(lastRun), noteColor: .red) {
                        Text(lastRun.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    if !lastRun.outputTail.isEmpty {
                        Text(lastRun.outputTail.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text(lastRun == nil ? "Run" : "Last run")
            }

            Section {
                SettingsRow(title: "Delete this command") {
                    Button("Delete…", role: .destructive, action: onDelete)
                }
            } footer: {
                Text(CommandsPane.trustNote)
            }
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                command.workingDirectory = CommandsPane.displayPath(url.path, home: FileManager.default.homeDirectoryForCurrentUser.path)
            }
        }
    }

    private var preview: String {
        let item = Self.sampleItem
        let prompt = CommandTemplate.renderPrompt(command.prompt, item: item)
        return CommandTemplate.renderCommandLine(command.commandLine, prompt: prompt, item: item)
    }

    private func statusTitle(_ run: CommandRunRecord) -> String {
        switch run.outcome {
        case .running: return "Running…"
        case .succeeded: return "Worked"
        case .failed: return "Failed"
        }
    }

    private func failureMessage(_ run: CommandRunRecord) -> String? {
        if case .failed(let message) = run.outcome { return message }
        return nil
    }
}
