import AppKit
import Foundation
import Observation

enum AgentsHint {
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// One quiet line in the popover while a skill is outdated, until the
    /// user closes it for this app version.
    static func shouldShow(outdated: Bool, dismissedVersion: String?, appVersion: String) -> Bool {
        outdated && dismissedVersion != appVersion
    }
}

/// State and actions of the harness rows in Settings > Agents.
@MainActor
@Observable
final class AgentsController {
    struct Row: Identifiable, Equatable {
        let spec: HarnessSpec
        var plan: HarnessInstallPlan
        /// State of the skill in `plan.skillFolder`.
        var skillState: SkillRowState
        /// The row whose folder really holds the skill this harness reads.
        /// Nil while that folder has no skill: then this row installs it
        /// into `plan.skillFolder` itself.
        var coveredBy: HarnessID?
        var connection: ServerConnection
        var message: String?
        var manualCommand: String?
        var isBusy = false
        /// False when the harness has no CLI or Roger did not find it: then
        /// the server can only be added by hand.
        var hasCLI = true

        var id: HarnessID { spec.id }

        /// An unreadable config counts as not connected: Roger cannot tell.
        private var serverAbsent: Bool { connection == .notConnected || connection == .unknown }

        /// "Show setup" when only the server is missing and Roger cannot
        /// add it (no CLI), "Install" while the row has nothing of its own,
        /// "Update" when something is out of date, nil when all is well.
        var primaryAction: String? {
            let skillOK = coveredBy != nil || skillState == .upToDate
            if skillOK, connection != .connected, !hasCLI { return "Show setup" }
            let skillFresh = coveredBy != nil || skillState == .notInstalled
            if skillFresh, serverAbsent { return "Install" }
            if !skillOK || connection != .connected { return "Update" }
            return nil
        }

        /// A covered row leaves the skill to the covering row.
        var canUninstall: Bool {
            (coveredBy == nil && skillState != .notInstalled) || !serverAbsent
        }
    }

    private(set) var rows: [Row] = []
    let executableChoice: RogerMCPLocation.Choice

    @ObservationIgnored private let home: URL
    @ObservationIgnored let installer: SkillInstaller
    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private var searchPath: [String]?
    /// Drops a refresh that finished after a newer one.
    @ObservationIgnored private var refreshGeneration = 0

    /// `executableChoice` is looked up from `appBundle` and `links` when
    /// not given (`live()` looks it up off the main actor).
    init(
        home: URL,
        installer: SkillInstaller,
        runner: any CommandRunner,
        appBundle: URL,
        searchPath: [String]? = nil,
        links: [String] = RogerMCPLocation.homebrewLinks,
        executableChoice: RogerMCPLocation.Choice? = nil
    ) {
        self.home = home
        self.installer = installer
        self.runner = runner
        self.searchPath = searchPath
        self.executableChoice = executableChoice ?? RogerMCPLocation.choose(appBundle: appBundle, links: links)
        self.appBundle = appBundle
    }

    /// Nil when this copy of Roger has no bundled skill. Reads the skill
    /// and checks the `roger-mcp` paths off the main actor.
    static func live() async -> AgentsController? {
        let appBundle = Bundle.main.bundleURL
        let found = await Task.detached(priority: .userInitiated) { () -> (BundledSkill, RogerMCPLocation.Choice)? in
            guard let skill = BundledSkill.load() else { return nil }
            return (skill, RogerMCPLocation.choose(appBundle: appBundle))
        }.value
        guard let (skill, choice) = found else { return nil }
        return AgentsController(
            home: FileManager.default.homeDirectoryForCurrentUser,
            installer: .live(skill: skill),
            runner: ProcessCommandRunner(),
            appBundle: appBundle,
            executableChoice: choice
        )
    }

    private var executable: String? {
        if case .usable(let path) = executableChoice { return path }
        return nil
    }

    /// What `refresh()` reads from disk for one row.
    private struct Snapshot: Sendable {
        let plan: HarnessInstallPlan
        let skillState: SkillRowState
        let connection: ServerConnection
        let hasCLI: Bool
    }

    /// Reads detection, skill states and config files again, off the main
    /// actor (`~/.claude.json` can be large). Messages and busy flags stay,
    /// so another row's work keeps its spinner.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let home = self.home
        let installer = self.installer
        let executable = self.executable
        // Until the login shell answered, a harness with a CLI counts as
        // having it, so the rows show at once.
        let knownPath = searchPath
        let snapshots = await Task.detached(priority: .userInitiated) {
            SkillInstallPlanner.plan(for: HarnessCatalog.detected(home: home), home: home).map { plan in
                Snapshot(
                    plan: plan,
                    skillState: installer.state(of: plan.skillFolder),
                    connection: HarnessRegistration.connection(plan.harness, home: home, executable: executable),
                    hasCLI: Self.hasCLI(plan.harness, in: knownPath)
                )
            }
        }.value
        guard generation == refreshGeneration else { return }
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = snapshots.map { snapshot in
            let id = snapshot.plan.harness.id
            return Row(
                spec: snapshot.plan.harness,
                plan: snapshot.plan,
                skillState: snapshot.skillState,
                coveredBy: snapshot.skillState == .notInstalled ? nil : snapshot.plan.coveredBy,
                connection: snapshot.connection,
                message: previous[id]?.message,
                manualCommand: previous[id]?.manualCommand,
                isBusy: previous[id]?.isBusy ?? false,
                hasCLI: snapshot.hasCLI
            )
        }
        guard knownPath == nil else { return }
        let path = await resolvedSearchPath()
        guard generation == refreshGeneration else { return }
        for index in rows.indices {
            rows[index].hasCLI = Self.hasCLI(rows[index].spec, in: path)
        }
    }

    /// Nil `searchPath`: not looked up yet, so any CLI counts.
    nonisolated private static func hasCLI(_ spec: HarnessSpec, in searchPath: [String]?) -> Bool {
        guard let cli = spec.cli else { return false }
        guard let searchPath else { return true }
        return CLILocator.find(cli, in: searchPath) != nil
    }

    /// Installs or updates the skill (unless another row covers it), then
    /// registers the server.
    func install(_ id: HarnessID) async {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        setBusy(id, true)
        var notes: [String] = []
        var command: String?
        if row.coveredBy == nil {
            do {
                if case .updated(let backup?) = try installer.install(into: row.plan.skillFolder) {
                    notes.append("Your changed skill was saved as \(backup.lastPathComponent).")
                }
            } catch {
                notes.append(error.localizedDescription)
            }
        }
        if let executable {
            let outcome = await registrar().register(row.spec, executable: executable)
            if outcome.kind == .manual {
                notes.append(outcome.message ?? "")
                command = outcome.command
            }
        } else if case .unusable(let reason) = executableChoice {
            notes.append(reason)
        }
        await finish(id, message: notes.isEmpty ? nil : notes.joined(separator: " "), command: command)
    }

    /// False when a changed skill needs a confirmation first; call again
    /// with `confirmChanged: true` after the user agreed.
    func uninstall(_ id: HarnessID, confirmChanged: Bool) async -> Bool {
        guard let row = rows.first(where: { $0.id == id }) else { return true }
        var notes: [String] = []
        var command: String?
        if row.coveredBy == nil {
            do {
                if try installer.uninstall(from: row.plan.skillFolder, confirmChanged: confirmChanged) == .needsConfirmation {
                    return false
                }
            } catch {
                notes.append(error.localizedDescription)
            }
        }
        setBusy(id, true)
        if let executable {
            let outcome = await registrar().unregister(row.spec, executable: executable)
            if outcome.kind == .manual {
                notes.append(outcome.message ?? "")
                command = outcome.command
            }
        }
        await finish(id, message: notes.isEmpty ? nil : notes.joined(separator: " "), command: command)
        return true
    }

    // MARK: - Claude Desktop

    /// Where Claude Desktop lives; the row shows only when it exists.
    @ObservationIgnored var claudeAppURL = URL(fileURLWithPath: "/Applications/Claude.app")
    @ObservationIgnored var desktopStore = DesktopRecordStore.live
    @ObservationIgnored var downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    @ObservationIgnored var tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Roger-mcpb", isDirectory: true)
    /// Set by the initializer, so tests and the Desktop actions use the same app.
    @ObservationIgnored var appBundle = Bundle.main.bundleURL
    /// Set by `refreshDesktop()`: the view body never touches the disk.
    private(set) var desktopAvailable = false
    private(set) var desktopRecord = DesktopRecord()
    var desktopMessage: String?
    /// True while an add or save runs; the view disables both buttons.
    private(set) var desktopBusy = false
    /// Shows a file in Finder; tests replace it.
    @ObservationIgnored var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// Desktop gets the bundle's own binary, never a Homebrew link.
    private var desktopExecutable: String? {
        if case .unusable = executableChoice { return nil }
        return RogerMCPLocation.bundled(in: appBundle).path
    }

    /// Reads the record and checks for Claude Desktop off the main actor.
    func refreshDesktop() async {
        let store = desktopStore
        let claude = claudeAppURL
        let (record, available) = await Task.detached(priority: .userInitiated) {
            (store.load(), FileManager.default.fileExists(atPath: claude.path))
        }.value
        desktopRecord = record
        desktopAvailable = available
    }

    func desktopAppMoved() -> Bool {
        guard let desktopExecutable else { return false }
        return desktopRecord.appMoved(currentExecutable: desktopExecutable)
    }

    /// Builds `roger.mcpb` in a temp folder and opens it with Claude
    /// Desktop, which shows its install dialog. Same name means an update.
    func addToClaudeDesktop() async {
        guard !desktopBusy else { return }
        desktopBusy = true
        defer { desktopBusy = false }
        guard let executable = desktopExecutable else {
            if case .unusable(let reason) = executableChoice { desktopMessage = reason }
            return
        }
        let folder = tempFolder
        let bundle = appBundle
        let store = desktopStore
        do {
            let mcpb: URL? = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try DesktopExtensionBuilder.iconPNG(for: bundle).map {
                    try DesktopExtensionBuilder.buildExtension(
                        executable: executable, version: AgentsHint.appVersion, iconPNG: $0, in: folder, archiver: DittoArchiver()
                    )
                }
            }.value
            guard let mcpb else {
                desktopMessage = "Roger could not draw its icon for the extension."
                return
            }
            _ = try await NSWorkspace.shared.open([mcpb], withApplicationAt: claudeAppURL, configuration: NSWorkspace.OpenConfiguration())
            try await Task.detached {
                var record = store.load()
                record.extensionCommand = executable
                record.extensionAddedAt = Date()
                try store.save(record)
            }.value
            desktopMessage = "Claude Desktop shows its install dialog. Confirm it there."
        } catch {
            desktopMessage = error.localizedDescription
        }
        await refreshDesktop()
    }

    /// Writes `ingest-roger.zip` to Downloads and shows it in Finder.
    func saveSkillForClaudeDesktop() async {
        guard !desktopBusy else { return }
        desktopBusy = true
        defer { desktopBusy = false }
        let skill = installer.skill
        let folder = downloadsFolder
        let store = desktopStore
        do {
            let zip = try await Task.detached(priority: .userInitiated) {
                let zip = try DesktopExtensionBuilder.buildSkillZip(skill, in: folder, archiver: DittoArchiver())
                var record = store.load()
                record.skillSavedAt = Date()
                try store.save(record)
                return zip
            }.value
            reveal(zip)
            desktopMessage = "Upload \(zip.lastPathComponent) in Claude > Settings > Capabilities > Skills."
        } catch {
            desktopMessage = error.localizedDescription
        }
        await refreshDesktop()
    }

    // MARK: - Helpers

    /// The login shell's `PATH` and the extra folders, looked up once.
    private func resolvedSearchPath() async -> [String] {
        if searchPath == nil {
            let path = await CLILocator.loginShellPATH(runner: runner, home: home)
            searchPath = CLILocator.searchPath(loginShellPATH: path, home: home)
        }
        return searchPath ?? CLILocator.extraDirectories
    }

    private func registrar() async -> HarnessRegistrar {
        HarnessRegistrar(home: home, runner: runner, searchPath: await resolvedSearchPath())
    }

    private func setBusy(_ id: HarnessID, _ busy: Bool) {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].isBusy = busy }
    }

    private func finish(_ id: HarnessID, message: String?, command: String?) async {
        await refresh()
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].message = message
            rows[index].manualCommand = command
            rows[index].isBusy = false
        }
    }
}
