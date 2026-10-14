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

        var id: HarnessID { spec.id }

        /// "Install" while the row has nothing of its own, "Update" when
        /// something is out of date, nil when all is well.
        var primaryAction: String? {
            let skillFresh = coveredBy != nil || skillState == .notInstalled
            if skillFresh, connection == .notConnected { return "Install" }
            let skillOK = coveredBy != nil || skillState == .upToDate
            if !skillOK || connection != .connected { return "Update" }
            return nil
        }

        /// A covered row leaves the skill to the covering row.
        var canUninstall: Bool {
            (coveredBy == nil && skillState != .notInstalled) || connection != .notConnected
        }
    }

    private(set) var rows: [Row] = []
    let executableChoice: RogerMCPLocation.Choice

    @ObservationIgnored private let home: URL
    @ObservationIgnored let installer: SkillInstaller
    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private var searchPath: [String]?

    init(home: URL, installer: SkillInstaller, runner: any CommandRunner, appBundle: URL, searchPath: [String]? = nil, links: [String] = RogerMCPLocation.homebrewLinks) {
        self.home = home
        self.installer = installer
        self.runner = runner
        self.searchPath = searchPath
        self.executableChoice = RogerMCPLocation.choose(appBundle: appBundle, links: links)
    }

    /// Nil when this copy of Roger has no bundled skill.
    static func live() -> AgentsController? {
        guard let skill = BundledSkill.load() else { return nil }
        return AgentsController(
            home: FileManager.default.homeDirectoryForCurrentUser,
            installer: .live(skill: skill),
            runner: ProcessCommandRunner(),
            appBundle: Bundle.main.bundleURL
        )
    }

    private var executable: String? {
        if case .usable(let path) = executableChoice { return path }
        return nil
    }

    /// Reads detection, skill states and config files again. Messages and
    /// busy flags stay, so another row's work keeps its spinner.
    func refresh() {
        let plans = SkillInstallPlanner.plan(for: HarnessCatalog.detected(home: home), home: home)
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = plans.map { plan in
            let skillState = installer.state(of: plan.skillFolder)
            return Row(
                spec: plan.harness,
                plan: plan,
                skillState: skillState,
                coveredBy: skillState == .notInstalled ? nil : plan.coveredBy,
                connection: executable.map { HarnessRegistration.connection(plan.harness, home: home, executable: $0) } ?? .unknown,
                message: previous[plan.harness.id]?.message,
                manualCommand: previous[plan.harness.id]?.manualCommand,
                isBusy: previous[plan.harness.id]?.isBusy ?? false
            )
        }
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
        finish(id, message: notes.isEmpty ? nil : notes.joined(separator: " "), command: command)
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
        finish(id, message: notes.isEmpty ? nil : notes.joined(separator: " "), command: command)
        return true
    }

    // MARK: - Helpers

    private func registrar() async -> HarnessRegistrar {
        if searchPath == nil {
            let path = await CLILocator.loginShellPATH(runner: runner, home: home)
            searchPath = CLILocator.searchPath(loginShellPATH: path)
        }
        return HarnessRegistrar(home: home, runner: runner, searchPath: searchPath ?? CLILocator.extraDirectories)
    }

    private func setBusy(_ id: HarnessID, _ busy: Bool) {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].isBusy = busy }
    }

    private func finish(_ id: HarnessID, message: String?, command: String?) {
        refresh()
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].message = message
            rows[index].manualCommand = command
            rows[index].isBusy = false
        }
    }
}
