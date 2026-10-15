import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Commands")

protocol TerminalLaunching: Sendable {
    func launch(commandLine: String, workingDirectory: URL, terminal: TerminalApp) async throws
}

/// Runs configured commands after Roger saved an item. At most one headless
/// run per command: triggers during a run are merged into one follow-up run
/// with the newest item (an ingest takes everything pending anyway).
/// Interactive runs open a terminal each time and are not queued.
@MainActor @Observable
final class CommandScheduler {
    private(set) var lastRuns: [UUID: CommandRunRecord] = [:]
    private(set) var unseenFailures: [UUID] = []

    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let launcher: any TerminalLaunching
    @ObservationIgnored private let environment: @MainActor () async -> [String: String]
    @ObservationIgnored private let home: URL
    @ObservationIgnored private var active: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pending: [UUID: (AgentCommand, CommandItemInfo)] = [:]
    @ObservationIgnored private var launches: [Task<Void, Never>] = []

    init(runner: any CommandRunner,
         launcher: any TerminalLaunching,
         environment: @escaping @MainActor () async -> [String: String],
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        self.launcher = launcher
        self.environment = environment
        self.home = home
    }

    func trigger(_ command: AgentCommand, item: CommandItemInfo) {
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
            launches.append(Task { [launcher] in
                do {
                    try await launcher.launch(commandLine: line, workingDirectory: directory, terminal: command.terminal)
                    self.finish(command, startedAt: started, outcome: .succeeded, tail: [])
                } catch {
                    self.finish(command, startedAt: started, outcome: .failed(error.localizedDescription), tail: [])
                }
            })
        case .headless:
            if active[command.id] != nil {
                pending[command.id] = (command, item)
                return
            }
            startHeadless(command, line: line, directory: directory)
        }
    }

    func markFailuresSeen() {
        unseenFailures.removeAll()
    }

    func waitUntilIdle() async {
        while true {
            let tasks = Array(active.values) + launches
            if tasks.isEmpty && pending.isEmpty { return }
            for task in tasks { await task.value }
            launches.removeAll()
            await Task.yield()
        }
    }

    private func startHeadless(_ command: AgentCommand, line: String, directory: URL) {
        let started = Date.now
        lastRuns[command.id] = CommandRunRecord(commandID: command.id, commandName: command.name, startedAt: started, outcome: .running)
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let timeout = Duration.seconds(max(1, command.timeoutMinutes) * 60)
        active[command.id] = Task { [runner, environment] in
            let env = await environment()
            let result = await runner.run(URL(fileURLWithPath: shell), ["-l", "-c", line],
                                          environment: env, currentDirectory: directory, timeout: timeout)
            let outcome: CommandRunRecord.Outcome
            switch result.status {
            case .exited(0): outcome = .succeeded
            case .exited(let code): outcome = .failed("Exited with code \(code).")
            case .timedOut: outcome = .failed("Timed out after \(command.timeoutMinutes) minutes.")
            case .failedToStart(let reason): outcome = .failed("Could not start: \(reason)")
            }
            self.finish(command, startedAt: started, outcome: outcome,
                        tail: CommandRunRecord.tail(of: result.stdout + "\n" + result.stderr))
            self.active[command.id] = nil
            if let (next, item) = self.pending.removeValue(forKey: command.id) {
                self.trigger(next, item: item)
            }
        }
    }

    private func finish(_ command: AgentCommand, startedAt: Date, outcome: CommandRunRecord.Outcome, tail: [String]) {
        lastRuns[command.id] = CommandRunRecord(commandID: command.id, commandName: command.name,
                                                startedAt: startedAt, outcome: outcome, outputTail: tail)
        switch outcome {
        case .failed(let message):
            logger.warning("Command \(command.name, privacy: .public) failed: \(message, privacy: .public)")
            if !unseenFailures.contains(command.id) { unseenFailures.append(command.id) }
        case .succeeded:
            unseenFailures.removeAll { $0 == command.id }
        case .running:
            break
        }
    }
}
