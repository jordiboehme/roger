import Foundation
import Observation

/// The steps of "Suggest Commands" as the sheet shows them, so the user
/// sees how far the search got and where it waits.
@MainActor
@Observable
final class SuggestionProgress {
    enum StepID: Hashable, Sendable {
        case searchPath
        case findAgents
        case readSettings(HarnessID)
        case askClaude
        case prepare
    }

    enum State: Equatable, Sendable {
        case waiting
        case running
        case done
        /// It did not work, a fallback was used and the list goes on.
        case warning(String)
    }

    struct Step: Identifiable, Equatable, Sendable {
        let id: StepID
        let title: String
        var state: State = .waiting
        /// Short text at the end of the line once done (the found agents).
        var detail: String?
        var startedAt: Date?
        /// The folder the find step looks at right now.
        var checking: String?
    }

    private(set) var steps: [Step] = [
        Step(id: .searchPath, title: "Read the search path from your login shell"),
        Step(id: .findAgents, title: "Look for coding agents"),
        Step(id: .prepare, title: "Prepare the suggestions"),
    ]

    /// Folder updates come from another thread; older ones are dropped.
    private var checkingSequence = 0

    func step(_ id: StepID) -> Step? {
        steps.first { $0.id == id }
    }

    func start(_ id: StepID, now: Date = Date()) {
        update(id) {
            $0.state = .running
            $0.startedAt = now
        }
    }

    func finish(_ id: StepID, detail: String? = nil) {
        update(id) {
            $0.state = .done
            $0.detail = detail
            $0.checking = nil
        }
    }

    func warn(_ id: StepID, _ note: String) {
        update(id) {
            $0.state = .warning(note)
            $0.checking = nil
        }
    }

    /// The find step looks at `folder`. Ignored when an update with a
    /// higher `sequence` came first or the step is no longer running.
    func checking(_ folder: String, sequence: Int) {
        guard sequence > checkingSequence else { return }
        checkingSequence = sequence
        guard step(.findAgents)?.state == .running else { return }
        update(.findAgents) { $0.checking = folder }
    }

    /// Adds steps right before "Prepare the suggestions".
    func insertBeforeLast(_ new: [Step]) {
        let index = steps.firstIndex { $0.id == .prepare } ?? steps.endIndex
        steps.insert(contentsOf: new, at: index)
    }

    private func update(_ id: StepID, _ change: (inout Step) -> Void) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[index])
    }
}

/// The search path for harness CLIs and the shell's `CODEX_HOME`.
struct CommandSearchPathLookup: Equatable, Sendable {
    var path: [String]
    var codexHome: String?
    /// False when the login shell did not answer and only the standard
    /// folders are used.
    var fromShell: Bool
}

/// The login shell's `PATH` plus the extra folders, looked up once per
/// launch for the commands (the shell takes a moment to answer), and the
/// shell's `CODEX_HOME` for Suggest Commands.
@MainActor
final class CommandSearchPathCache {
    private var cached: CommandSearchPathLookup?

    func value(runner: any CommandRunner, home: URL) async -> [String] {
        await lookup(runner: runner, home: home).path
    }

    func lookup(runner: any CommandRunner, home: URL) async -> CommandSearchPathLookup {
        if let cached { return cached }
        let environment = await CLILocator.loginShellEnvironment(runner: runner, home: home)
        let path = CLILocator.searchPath(loginShellPATH: environment?.path, home: home)
        guard let environment else {
            // A shell that did not answer is asked again on the next run.
            return CommandSearchPathLookup(path: path, codexHome: nil, fromShell: false)
        }
        let lookup = CommandSearchPathLookup(path: path, codexHome: environment.codexHome, fromShell: true)
        cached = lookup
        return lookup
    }
}

/// Runs the steps of "Suggest Commands" and reports them to a
/// `SuggestionProgress`. Blocking file work runs off the main actor.
@MainActor
struct CommandSuggestionFinder {
    let home: URL
    let runner: any CommandRunner
    let searchPath: @MainActor () async -> CommandSearchPathLookup
    var claudeTimeout: Duration = .seconds(20)

    static let shellFallbackNote = "Shell did not answer - using the standard folders"
    static let noAgentsDetail = "None"

    static func claudeFallbackNote(_ status: CommandResult.Status, timeout: Duration) -> String {
        if status == .timedOut {
            return "Claude Code did not answer in \(timeout.components.seconds) s - using its settings file"
        }
        return "Claude Code did not answer - using its settings file"
    }

    func run(progress: SuggestionProgress) async -> [CommandSuggestion] {
        progress.start(.searchPath)
        let lookup = await searchPath()
        if lookup.fromShell {
            progress.finish(.searchPath)
        } else {
            progress.warn(.searchPath, Self.shellFallbackNote)
        }

        let detector = HarnessServerDetector(home: home, runner: runner, searchPath: lookup.path,
                                             codexHome: lookup.codexHome, timeout: claudeTimeout)
        progress.start(.findAgents)
        let report = Self.folderReporter(progress)
        let clis = await Task.detached(priority: .userInitiated) {
            var sequence = 0
            return detector.findCLIs { folder in
                sequence += 1
                report(folder, sequence)
            }
        }.value
        let names = clis.map(\.0.name)
        progress.finish(.findAgents, detail: names.isEmpty ? Self.noAgentsDetail : names.joined(separator: ", "))

        var added = clis.map { SuggestionProgress.Step(id: .readSettings($0.0.id), title: "Read the \($0.0.name) settings") }
        let claude = clis.first { $0.0.id == .claudeCode }?.1
        if claude != nil {
            added.append(SuggestionProgress.Step(id: .askClaude, title: "Ask Claude Code for its servers"))
        }
        progress.insertBeforeLast(added)

        var servers: [HarnessID: [ConfiguredServer]] = [:]
        for (spec, _) in clis {
            progress.start(.readSettings(spec.id))
            servers[spec.id] = await Task.detached(priority: .userInitiated) { detector.configuredServers(spec) }.value
            progress.finish(.readSettings(spec.id))
        }
        if let claude {
            progress.start(.askClaude)
            switch await detector.claudeMcpList(claude) {
            case .servers(let listed):
                // Config first: the first Crystalline server wins, as before.
                servers[.claudeCode, default: []] += listed
                progress.finish(.askClaude)
            case .failed(let status):
                progress.warn(.askClaude, Self.claudeFallbackNote(status, timeout: claudeTimeout))
            }
        }

        progress.start(.prepare)
        let found = clis.map { ($0.0.id, HarnessServers(configured: servers[$0.0.id] ?? [])) }
        let suggestions = CommandSuggestions.suggestions(for: found)
        progress.finish(.prepare)
        return suggestions
    }

    /// Hands a folder from the detached find to the main actor.
    private static func folderReporter(_ progress: SuggestionProgress) -> @Sendable (String, Int) -> Void {
        { folder, sequence in
            Task { @MainActor in progress.checking(folder, sequence: sequence) }
        }
    }
}
