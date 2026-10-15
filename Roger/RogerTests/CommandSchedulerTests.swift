import Foundation
import Testing
@testable import Roger

/// Holds each run until the test releases it.
actor GatedRunner: CommandRunner {
    private(set) var calls: [(args: [String], dir: URL)] = []
    private var gates: [CheckedContinuation<Void, Never>] = []
    var result = CommandResult(status: .exited(0), stdout: "ok", stderr: "")

    nonisolated func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult {
        await record(arguments, currentDirectory)
        await withCheckedContinuation { c in Task { await self.park(c) } }
        return await result
    }
    private func record(_ a: [String], _ d: URL) { calls.append((a, d)) }
    private func park(_ c: CheckedContinuation<Void, Never>) { gates.append(c) }
    func setResult(_ r: CommandResult) { result = r }
    func releaseAll() { let g = gates; gates = []; g.forEach { $0.resume() } }
    var parked: Int { gates.count }
}

struct NoLauncher: TerminalLaunching {
    func launch(commandLine: String, workingDirectory: URL, terminal: TerminalApp) async throws {}
}

@MainActor
struct CommandSchedulerTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roger-sched-\(UUID().uuidString)")

    private func item(_ n: Int) -> CommandItemInfo {
        CommandItemInfo(file: "/f\(n).md", key: "k\(n)", title: "T\(n)", kind: "log")
    }
    private func command() -> AgentCommand {
        AgentCommand(name: "C", commandLine: "echo {key}", prompt: "p", workingDirectory: dir.path)
    }
    private func until(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func manyTriggersDuringARunGiveOneFollowUpWithTheNewestItem() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = GatedRunner()
        let s = CommandScheduler(runner: runner, launcher: NoLauncher(), environment: { [:] })
        let c = command()
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        s.trigger(c, item: item(2))
        s.trigger(c, item: item(3))
        #expect(await runner.calls.count == 1)
        await runner.releaseAll()
        await until { await runner.parked == 1 }
        #expect(await runner.calls.count == 2)
        #expect(await runner.calls[1].args.last == "echo 'k3'")
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(await runner.calls.count == 2)
        #expect(s.lastRuns[c.id]?.outcome == .succeeded)
    }

    @Test func missingDirectoryFailsWithoutRunning() async {
        let runner = GatedRunner()
        let s = CommandScheduler(runner: runner, launcher: NoLauncher(), environment: { [:] })
        let c = AgentCommand(name: "C", commandLine: "echo", prompt: "", workingDirectory: "/no/such/dir-\(UUID())")
        s.trigger(c, item: item(1))
        await s.waitUntilIdle()
        #expect(await runner.calls.isEmpty)
        guard case .failed(let message) = s.lastRuns[c.id]?.outcome else { Issue.record("no failure"); return }
        #expect(message.contains("does not exist"))
        #expect(s.unseenFailures == [c.id])
    }

    @Test func nonZeroExitIsAFailureWithTail() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = GatedRunner()
        await runner.setResult(CommandResult(status: .exited(2), stdout: "a\nb", stderr: "boom"))
        let s = CommandScheduler(runner: runner, launcher: NoLauncher(), environment: { [:] })
        let c = command()
        s.trigger(c, item: item(1))
        await until { await runner.parked == 1 }
        await runner.releaseAll()
        await s.waitUntilIdle()
        #expect(s.lastRuns[c.id]?.outcome == .failed("Exited with code 2."))
        #expect(s.lastRuns[c.id]?.outputTail == ["a", "b", "boom"])
        s.markFailuresSeen()
        #expect(s.unseenFailures.isEmpty)
    }

    @Test func runsTheLoginShellWithTheRenderedLine() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = GatedRunner()
        let s = CommandScheduler(runner: runner, launcher: NoLauncher(), environment: { [:] })
        s.trigger(command(), item: item(7))
        await until { await runner.parked == 1 }
        let call = await runner.calls[0]
        #expect(call.args == ["-l", "-c", "echo 'k7'"])
        #expect(call.dir.standardizedFileURL.path == dir.standardizedFileURL.path)
        await runner.releaseAll()
        await s.waitUntilIdle()
    }

    @Test func tailKeepsLastTwentyNonEmptyLines() {
        let text = (1...30).map(String.init).joined(separator: "\n") + "\n\n"
        #expect(CommandRunRecord.tail(of: text) == (11...30).map(String.init))
    }
}
