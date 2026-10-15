import Foundation
import Testing
@testable import Roger

/// Holds each run until the test releases it, or until its task is
/// cancelled. Records `stopAll()` and the cancellations it saw.
private actor GatedRunner: CommandRunner {
    private(set) var calls: [(args: [String], dir: URL)] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelled = 0
    nonisolated let stops = LockedCounter()
    var result = CommandResult(status: .exited(0), stdout: "ok", stderr: "")

    nonisolated func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult {
        await record(arguments, currentDirectory)
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in Task { await self.park(c) } }
        } onCancel: {
            Task { await self.cancelAll() }
        }
        if Task.isCancelled { return CommandResult(status: .stopped, stdout: "", stderr: "") }
        return await result
    }

    nonisolated func stopAll() { stops.increment() }

    private func record(_ a: [String], _ d: URL) { calls.append((a, d)) }
    private func park(_ c: CheckedContinuation<Void, Never>) { gates.append(c) }
    private func cancelAll() {
        cancelled += 1
        releaseAll()
    }
    func setResult(_ r: CommandResult) { result = r }
    func releaseAll() { let g = gates; gates = []; g.forEach { $0.resume() } }
    var parked: Int { gates.count }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct NoLauncher: TerminalLaunching {
    func launch(commandLine: String, workingDirectory: URL, terminal: TerminalApp) async throws {}
}

private struct FailingLauncher: TerminalLaunching {
    func launch(commandLine: String, workingDirectory: URL, terminal: TerminalApp) async throws {
        throw TerminalLaunchError.notInstalled("Warp is not installed.")
    }
}

/// Answers the questions when the test says so.
@MainActor
private final class FakeConfirmer: CommandConfirming {
    private(set) var asked: [(id: UUID, name: String, title: String)] = []
    private(set) var updates: [String] = []
    private(set) var dismissed: [UUID] = []
    private var open: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var openCount: Int { open.count }

    func confirm(commandID: UUID, commandName: String, itemTitle: String) async -> Bool {
        asked.append((commandID, commandName, itemTitle))
        return await withCheckedContinuation { open[commandID] = $0 }
    }

    func update(commandID: UUID, itemTitle: String) {
        updates.append(itemTitle)
    }

    func dismiss(commandID: UUID) {
        dismissed.append(commandID)
        answer(commandID, false)
    }

    func answer(_ id: UUID, _ allowed: Bool) {
        open.removeValue(forKey: id)?.resume(returning: allowed)
    }
}

/// The saved commands the scheduler looks up.
@MainActor
private final class CommandStore {
    var commands: [UUID: AgentCommand] = [:]
    func add(_ command: AgentCommand) { commands[command.id] = command }
}

@MainActor
struct CommandSchedulerTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roger-sched-\(UUID().uuidString)")

    private func item(_ n: Int) -> CommandItemInfo {
        CommandItemInfo(file: "/f\(n).md", key: "k\(n)", title: "T\(n)", kind: "log")
    }
    private func command(ask: Bool = false, mode: CommandMode = .headless) -> AgentCommand {
        AgentCommand(name: "C", commandLine: "echo {key}", prompt: "p", workingDirectory: dir.path, mode: mode, askBeforeRunning: ask)
    }
    private func until(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }
    private func makeDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    private func removeDir() {
        try? FileManager.default.removeItem(at: dir)
    }
    private func scheduler(_ runner: any CommandRunner, store: CommandStore, confirmer: FakeConfirmer = FakeConfirmer(),
                           launcher: any TerminalLaunching = NoLauncher()) -> CommandScheduler {
        CommandScheduler(runner: runner, launcher: launcher, confirmer: confirmer,
                         lookup: { store.commands[$0] }, environment: { [:] })
    }

    @Test func manyTriggersDuringARunGiveOneFollowUpWithTheNewestItem() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = command()
        store.add(c)
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        s.trigger(c, item: item(2))
        s.trigger(c, item: item(3))
        #expect(await runner.calls.count == 1)
        await runner.releaseAll()
        await until { await runner.parked == 1 }
        let calls = await runner.calls
        try #require(calls.count == 2)
        #expect(calls[1].args.last == "echo 'k3'")
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(await runner.calls.count == 2)
        #expect(s.lastRuns[c.id]?.outcome == .succeeded)
    }

    @Test func theFollowUpRunsTheCommandAsSavedNow() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        var c = command()
        store.add(c)
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        s.trigger(c, item: item(2))
        c.commandLine = "edited {key}"
        store.add(c)
        await runner.releaseAll()
        await until { await runner.parked == 1 }
        let calls = await runner.calls
        try #require(calls.count == 2)
        #expect(calls[1].args.last == "edited 'k2'")
        await runner.releaseAll()
        await s.waitUntilIdle()
    }

    @Test func aCommandDeletedDuringARunHasNoFollowUpAndNoFailure() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        await runner.setResult(CommandResult(status: .exited(1), stdout: "", stderr: ""))
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = command()
        store.add(c)
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        s.trigger(c, item: item(2))
        store.commands[c.id] = nil
        s.forget(c.id)
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(await runner.calls.count == 1)
        #expect(s.lastRuns[c.id] == nil)
        #expect(s.unseenFailures.isEmpty)
    }

    @Test func forgetDropsTheLastRunAndTheFailure() async {
        let runner = GatedRunner()
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = AgentCommand(name: "C", commandLine: "echo", prompt: "", workingDirectory: "/no/such/dir-\(UUID())")
        store.add(c)
        s.trigger(c, item: item(1))
        #expect(s.unseenFailures == [c.id])
        s.forget(c.id)
        #expect(s.unseenFailures.isEmpty)
        #expect(s.lastRuns[c.id] == nil)
    }

    @Test func missingDirectoryFailsWithoutRunning() async {
        let runner = GatedRunner()
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = AgentCommand(name: "C", commandLine: "echo", prompt: "", workingDirectory: "/no/such/dir-\(UUID())")
        store.add(c)
        s.trigger(c, item: item(1))
        await s.waitUntilIdle()
        #expect(await runner.calls.isEmpty)
        guard case .failed(let message) = s.lastRuns[c.id]?.outcome else { Issue.record("no failure"); return }
        #expect(message.contains("does not exist"))
        #expect(s.unseenFailures == [c.id])
    }

    @Test func nonZeroExitIsAFailureWithTail() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        await runner.setResult(CommandResult(status: .exited(2), stdout: "a\nb", stderr: "boom"))
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = command()
        store.add(c)
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(s.lastRuns[c.id]?.outcome == .failed("Exited with code 2."))
        #expect(s.lastRuns[c.id]?.outputTail == ["a", "b", "boom"])
        s.markFailuresSeen()
        #expect(s.unseenFailures.isEmpty)
    }

    @Test func aSuccessClearsTheFailure() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        await runner.setResult(CommandResult(status: .exited(2), stdout: "", stderr: ""))
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = command()
        store.add(c)
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(s.unseenFailures == [c.id])
        await runner.setResult(CommandResult(status: .exited(0), stdout: "", stderr: ""))
        s.trigger(c, item: item(2))
        await until { await runner.parked == 1 }
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(s.unseenFailures.isEmpty)
        #expect(s.lastRuns[c.id]?.outcome == .succeeded)
    }

    @Test func aFailureWhileThePaneIsVisibleRaisesNoBanner() async {
        let runner = GatedRunner()
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = AgentCommand(name: "C", commandLine: "echo", prompt: "", workingDirectory: "/no/such/dir-\(UUID())")
        store.add(c)
        s.isPaneVisible = true
        s.trigger(c, item: item(1))
        #expect(s.unseenFailures.isEmpty)
        #expect(s.lastRuns[c.id]?.outcome != nil)
        s.isPaneVisible = false
        s.trigger(c, item: item(2))
        #expect(s.unseenFailures == [c.id])
        s.isPaneVisible = true
        #expect(s.unseenFailures.isEmpty)
    }

    @Test func interactiveLaunchFailureIsRecorded() async throws {
        try makeDir()
        defer { removeDir() }
        let store = CommandStore()
        let s = scheduler(GatedRunner(), store: store, launcher: FailingLauncher())
        let c = command(mode: .interactive)
        store.add(c)
        s.trigger(c, item: item(1))
        await s.waitUntilIdle()
        #expect(s.lastRuns[c.id]?.outcome == .failed("Warp is not installed."))
        #expect(s.unseenFailures == [c.id])
    }

    @Test func outcomeTexts() {
        #expect(CommandScheduler.outcome(of: .timedOut, timeoutMinutes: 1) == .failed("Timed out after 1 minute."))
        #expect(CommandScheduler.outcome(of: .timedOut, timeoutMinutes: 10) == .failed("Timed out after 10 minutes."))
        #expect(CommandScheduler.outcome(of: .failedToStart("no shell"), timeoutMinutes: 10) == .failed("Could not start: no shell"))
        #expect(CommandScheduler.outcome(of: .exited(0), timeoutMinutes: 10) == .succeeded)
        #expect(CommandScheduler.outcome(of: .stopped, timeoutMinutes: 10) == .failed("Stopped because Roger quit."))
    }

    @Test func aTimeoutBelowOneMinuteRunsForOneMinute() {
        var c = AgentCommand.blank()
        c.timeoutMinutes = 0
        #expect(c.effectiveTimeoutMinutes == 1)
        c.timeoutMinutes = 5
        #expect(c.effectiveTimeoutMinutes == 5)
    }

    @Test func runsTheLoginShellWithTheRenderedLine() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let s = scheduler(runner, store: store)
        let c = command()
        store.add(c)
        s.trigger(c, item: item(7))
        await until { await runner.parked == 1 }
        let call = try #require(await runner.calls.first)
        #expect(call.args == ["-l", "-c", "echo 'k7'"])
        #expect(call.dir.standardizedFileURL.path == dir.standardizedFileURL.path)
        await runner.releaseAll()
        await s.waitUntilIdle()
    }

    @Test func tailKeepsLastTwentyNonEmptyLines() {
        let text = (1...30).map(String.init).joined(separator: "\n") + "\n\n"
        #expect(CommandRunRecord.tail(of: text) == (11...30).map(String.init))
    }

    // MARK: - Ask before running

    @Test func allowRunsTheCommand() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let confirmer = FakeConfirmer()
        let s = scheduler(runner, store: store, confirmer: confirmer)
        let c = command(ask: true)
        store.add(c)
        s.trigger(c, item: item(1))
        await until { confirmer.openCount == 1 }
        #expect(confirmer.asked.map(\.title) == ["T1"])
        #expect(confirmer.asked.first?.name == "C")
        #expect(await runner.calls.isEmpty)
        confirmer.answer(c.id, true)
        await until { await runner.parked == 1 }
        #expect(await runner.calls.first?.args.last == "echo 'k1'")
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(s.lastRuns[c.id]?.outcome == .succeeded)
    }

    @Test func notNowSkipsTheRun() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let confirmer = FakeConfirmer()
        let s = scheduler(runner, store: store, confirmer: confirmer)
        let c = command(ask: true)
        store.add(c)
        s.trigger(c, item: item(1))
        await until { confirmer.openCount == 1 }
        confirmer.answer(c.id, false)
        await s.waitUntilIdle()
        #expect(await runner.calls.isEmpty)
        #expect(s.lastRuns[c.id] == nil)
        // Nothing was queued: the next trigger asks again.
        s.trigger(c, item: item(2))
        await until { confirmer.openCount == 1 }
        #expect(confirmer.asked.count == 2)
        confirmer.answer(c.id, false)
        await s.waitUntilIdle()
    }

    @Test func triggersWhileAskingUpdateTheQuestionAndAllowRunsTheNewestItem() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let confirmer = FakeConfirmer()
        let s = scheduler(runner, store: store, confirmer: confirmer)
        let c = command(ask: true)
        store.add(c)
        s.trigger(c, item: item(1))
        await until { confirmer.openCount == 1 }
        s.trigger(c, item: item(2))
        s.trigger(c, item: item(3))
        #expect(confirmer.asked.count == 1)
        #expect(confirmer.updates == ["T2", "T3"])
        confirmer.answer(c.id, true)
        await until { await runner.parked == 1 }
        let calls = await runner.calls
        try #require(calls.count == 1)
        #expect(calls[0].args.last == "echo 'k3'")
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(await runner.calls.count == 1)
    }

    @Test func runNowDoesNotAsk() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let confirmer = FakeConfirmer()
        let s = scheduler(runner, store: store, confirmer: confirmer)
        let c = command(ask: true)
        store.add(c)
        s.trigger(c, item: item(1), ask: false)
        await until { await runner.parked == 1 }
        #expect(confirmer.asked.isEmpty)
        await runner.releaseAll()
        await s.waitUntilIdle()
    }

    @Test func aCommandDeletedWhileAskingDoesNotRun() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let confirmer = FakeConfirmer()
        let s = scheduler(runner, store: store, confirmer: confirmer)
        let c = command(ask: true)
        store.add(c)
        s.trigger(c, item: item(1))
        await until { confirmer.openCount == 1 }
        store.commands[c.id] = nil
        s.forget(c.id)
        await s.waitUntilIdle()
        #expect(confirmer.dismissed == [c.id])
        #expect(await runner.calls.isEmpty)
    }

    // MARK: - Quit

    @Test func stopAllCancelsTheRunsAndStopsTheRunner() async throws {
        try makeDir()
        defer { removeDir() }
        let runner = GatedRunner()
        let store = CommandStore()
        let confirmer = FakeConfirmer()
        let s = scheduler(runner, store: store, confirmer: confirmer)
        let c = command()
        let asking = AgentCommand(name: "Ask", commandLine: "x", prompt: "", workingDirectory: dir.path, askBeforeRunning: true)
        store.add(c)
        store.add(asking)
        s.trigger(c, item: item(1))
        s.trigger(asking, item: item(1))
        await until { await runner.parked == 1 }
        await until { confirmer.openCount == 1 }
        s.trigger(c, item: item(2))

        s.stopAll()
        await s.waitUntilIdle()

        #expect(runner.stops.value == 1)
        #expect(await runner.cancelled == 1)
        // No follow-up, no question left and nothing new starts.
        #expect(await runner.calls.count == 1)
        #expect(confirmer.dismissed == [asking.id])
        s.trigger(c, item: item(3))
        await s.waitUntilIdle()
        #expect(await runner.calls.count == 1)
        #expect(s.unseenFailures.isEmpty)
    }
}
