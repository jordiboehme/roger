import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Commands")

protocol TerminalLaunching: Sendable {
    func launch(commandLine: String, workingDirectory: URL, terminal: TerminalApp) async throws
}

/// Asks "Run <command>?" before a command with "Ask before running" runs.
/// At most one question per command is open at a time.
@MainActor
protocol CommandConfirming: AnyObject {
    /// Shows the question and returns the answer: true for "Allow", false
    /// for "Not now" or when the question was dismissed.
    func confirm(commandID: UUID, commandName: String, itemTitle: String) async -> Bool
    /// The open question for `commandID` names `itemTitle` now.
    func update(commandID: UUID, itemTitle: String)
    /// Closes the open question for `commandID`; `confirm` returns false.
    func dismiss(commandID: UUID)
}

/// Runs configured commands after Roger saved an item. At most one headless
/// run per command: triggers during a run are merged into one follow-up run
/// with the newest item (an ingest takes everything pending anyway).
/// Interactive runs open a terminal each time and are not queued. A command
/// with "Ask before running" waits for "Allow" first.
@MainActor @Observable
final class CommandScheduler {
    private(set) var lastRuns: [UUID: CommandRunRecord] = [:]
    private(set) var unseenFailures: [UUID] = []
    /// True while Settings shows the Commands pane. A failure the user can
    /// see there does not raise the menu bar line.
    var isPaneVisible = false {
        didSet { if isPaneVisible { markFailuresSeen() } }
    }

    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let launcher: any TerminalLaunching
    @ObservationIgnored private let confirmer: any CommandConfirming
    /// The command as it is saved now. Nil when it was deleted.
    @ObservationIgnored private let lookup: @MainActor (UUID) -> AgentCommand?
    @ObservationIgnored private let environment: @MainActor () async -> [String: String]
    @ObservationIgnored private let home: URL
    /// The headless run of each command.
    @ObservationIgnored private var active: [UUID: Task<Void, Never>] = [:]
    /// The newest item a trigger during a headless run left for the follow-up.
    @ObservationIgnored private var pending: [UUID: CommandItemInfo] = [:]
    /// The newest item of each open question.
    @ObservationIgnored private var asking: [UUID: CommandItemInfo] = [:]
    /// Terminal launches and open questions. Each task removes itself.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Set by `stopAll()`: Roger quits, nothing new starts.
    @ObservationIgnored private var isStopped = false

    init(runner: any CommandRunner,
         launcher: any TerminalLaunching,
         confirmer: any CommandConfirming,
         lookup: @escaping @MainActor (UUID) -> AgentCommand?,
         environment: @escaping @MainActor () async -> [String: String],
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        self.launcher = launcher
        self.confirmer = confirmer
        self.lookup = lookup
        self.environment = environment
        self.home = home
    }

    /// Runs `command` for `item`. With `ask` false ("Run now" in Settings)
    /// the command runs without its question.
    func trigger(_ command: AgentCommand, item: CommandItemInfo, ask: Bool = true) {
        guard !isStopped else { return }
        if ask && command.askBeforeRunning {
            askFirst(command, item: item)
        } else {
            run(command, item: item)
        }
    }

    func markFailuresSeen() {
        unseenFailures.removeAll()
    }

    /// The command was deleted: drops its last run, its failure, its
    /// follow-up and its open question. A run that is going ends on its own
    /// and is not recorded.
    func forget(_ id: UUID) {
        lastRuns[id] = nil
        unseenFailures.removeAll { $0 == id }
        pending[id] = nil
        if asking.removeValue(forKey: id) != nil {
            confirmer.dismiss(commandID: id)
        }
    }

    /// Roger quits: no follow-up and no question runs any more, open
    /// questions close and every headless run gets SIGTERM, then SIGKILL
    /// after the grace time. Blocks for at most the runner's grace time.
    func stopAll() {
        isStopped = true
        pending.removeAll()
        for id in Array(asking.keys) {
            asking[id] = nil
            confirmer.dismiss(commandID: id)
        }
        for task in active.values { task.cancel() }
        runner.stopAll()
    }

    /// Waits until no run, launch or question is left.
    func waitUntilIdle() async {
        while let task = active.values.first ?? tasks.values.first {
            await task.value
            await Task.yield()
        }
    }

    // MARK: - Private

    private func askFirst(_ command: AgentCommand, item: CommandItemInfo) {
        if asking[command.id] != nil {
            asking[command.id] = item
            confirmer.update(commandID: command.id, itemTitle: item.title)
            return
        }
        asking[command.id] = item
        track { [confirmer] in
            let allowed = await confirmer.confirm(commandID: command.id, commandName: command.displayName, itemTitle: item.title)
            // Gone when the command was deleted or Roger quits.
            guard let newest = self.asking.removeValue(forKey: command.id) else { return }
            guard allowed, !self.isStopped, let current = self.lookup(command.id) else { return }
            self.run(current, item: newest)
        }
    }

    private func run(_ command: AgentCommand, item: CommandItemInfo) {
        if command.mode == .headless, active[command.id] != nil {
            pending[command.id] = item
            return
        }
        let directory = command.expandedWorkingDirectory(home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            finish(command, startedAt: .now, outcome: .failed("The working directory \(directory.path) does not exist."), tail: [])
            return
        }
        let prompt = CommandTemplate.renderPrompt(command.prompt, item: item)
        let line = CommandTemplate.renderCommandLine(command.commandLine, prompt: prompt, item: item)

        switch command.mode {
        case .interactive:
            let started = Date.now
            track { [launcher] in
                do {
                    try await launcher.launch(commandLine: line, workingDirectory: directory, terminal: command.terminal)
                    self.finish(command, startedAt: started, outcome: .succeeded, tail: [])
                } catch {
                    self.finish(command, startedAt: started, outcome: .failed(error.localizedDescription), tail: [])
                }
            }
        case .headless:
            startHeadless(command, line: line, directory: directory)
        }
    }

    /// Keeps `body`'s task until it ends, for `waitUntilIdle`.
    private func track(_ body: @escaping @MainActor () async -> Void) {
        let key = UUID()
        // The task runs on the main actor, so it starts only after this
        // function stored it, and its own removal comes last.
        tasks[key] = Task {
            await body()
            self.tasks[key] = nil
        }
    }

    private func startHeadless(_ command: AgentCommand, line: String, directory: URL) {
        let started = Date.now
        lastRuns[command.id] = CommandRunRecord(commandID: command.id, commandName: command.displayName, startedAt: started, outcome: .running)
        let minutes = command.effectiveTimeoutMinutes
        active[command.id] = Task { [runner, environment] in
            let env = await environment()
            let result = await runner.run(URL(fileURLWithPath: CLILocator.loginShell), ["-l", "-c", line],
                                          environment: env, currentDirectory: directory, timeout: .seconds(minutes * 60))
            self.finish(command, startedAt: started, outcome: Self.outcome(of: result.status, timeoutMinutes: minutes),
                        tail: CommandRunRecord.tail(of: result.stdout + "\n" + result.stderr))
            self.active[command.id] = nil
            // The follow-up runs the command as it is saved now.
            if let item = self.pending.removeValue(forKey: command.id), !self.isStopped,
               let next = self.lookup(command.id) {
                self.run(next, item: item)
            }
        }
    }

    static func outcome(of status: CommandResult.Status, timeoutMinutes: Int) -> CommandRunRecord.Outcome {
        switch status {
        case .exited(0): return .succeeded
        case .exited(let code): return .failed("Exited with code \(code).")
        case .timedOut: return .failed("Timed out after \(timeoutMinutes) \(timeoutMinutes == 1 ? "minute" : "minutes").")
        case .failedToStart(let reason): return .failed("Could not start: \(reason)")
        case .stopped: return .failed("Stopped because Roger quit.")
        }
    }

    private func finish(_ command: AgentCommand, startedAt: Date, outcome: CommandRunRecord.Outcome, tail: [String]) {
        // A deleted command leaves no run and no failure behind.
        guard lookup(command.id) != nil else { return }
        lastRuns[command.id] = CommandRunRecord(commandID: command.id, commandName: command.displayName,
                                                startedAt: startedAt, outcome: outcome, outputTail: tail)
        switch outcome {
        case .failed(let message):
            logger.warning("Command \(command.displayName, privacy: .public) failed: \(message, privacy: .public)")
            guard !isPaneVisible, !isStopped else { return }
            if !unseenFailures.contains(command.id) { unseenFailures.append(command.id) }
        case .succeeded:
            unseenFailures.removeAll { $0 == command.id }
        case .running:
            break
        }
    }
}
