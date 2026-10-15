import Foundation
import Testing
@testable import Roger

struct CommandRunnerTests {
    private let runner = ProcessCommandRunner()
    private let tmp = FileManager.default.temporaryDirectory

    @Test func hangingCommandTimesOut() async {
        let start = Date()
        let result = await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], currentDirectory: tmp, timeout: .milliseconds(500))
        #expect(result.status == .timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func commandThatIgnoresTermIsKilled() async throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let pidFile = folder.appendingPathComponent("pid")
        // The shell writes its pid (the process group) first. `sleep` inherits the ignored TERM.
        let start = Date()
        let result = await runner.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ > \"$0\"; trap \"\" TERM; sleep 30", pidFile.path],
            environment: [:], currentDirectory: tmp, timeout: .milliseconds(500)
        )
        #expect(result.status == .timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let group = try #require(pid_t(text))
        // A killed child may stay a zombie for a moment until launchd reaps it.
        var gone = false
        for _ in 0..<40 {
            let groupGone = kill(-group, 0) == -1 && errno == ESRCH
            let shellGone = kill(group, 0) == -1 && errno == ESRCH
            if groupGone, shellGone {
                gone = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone, "process group \(group) is still running")
    }

    @Test func stopAllEndsARunThatIgnoresTerm() async throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let pidFile = folder.appendingPathComponent("pid")
        let runner = ProcessCommandRunner()
        let run = Task {
            await runner.run(
                URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ > \"$0\"; trap \"\" TERM; sleep 30", pidFile.path],
                environment: [:], currentDirectory: tmp, timeout: .seconds(60)
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Give the shell a moment to set up the trap.
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        runner.stopAll()
        let result = await run.value
        #expect(result.status == .stopped)
        // SIGTERM is ignored, so the stop waits the grace time, then kills.
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aCancelledRunGetsTheGraceTimeBeforeSIGKILL() async throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let marker = folder.appendingPathComponent("cleaned-up")
        // On TERM the shell writes the marker before it exits.
        let script = "trap 'sleep 0.2; touch \"$0\"; exit 0' TERM; sleep 30 & wait"
        let runner = ProcessCommandRunner()
        let run = Task {
            await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", script, marker.path],
                             environment: [:], currentDirectory: tmp, timeout: .seconds(60))
        }
        try await Task.sleep(for: .milliseconds(300))
        run.cancel()
        let result = await run.value
        #expect(result.status == .stopped)
        #expect(FileManager.default.fileExists(atPath: marker.path), "SIGKILL came before the grace time was over")
    }

    @Test func stopAllWithoutRunsReturnsAtOnce() {
        let start = Date()
        ProcessCommandRunner().stopAll()
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func stdinIsClosed() async {
        // cat waits for input forever unless stdin is at end of file.
        let result = await runner.run(URL(fileURLWithPath: "/bin/cat"), [], environment: [:], currentDirectory: tmp, timeout: .seconds(5))
        #expect(result.status == .exited(0))
        #expect(result.stdout.isEmpty)
    }

    @Test func passesTheEnvironmentAndFolder() async {
        let result = await runner.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo \"$PATH\"; pwd -P"],
            environment: ["PATH": "/custom/bin:/usr/bin"], currentDirectory: URL(fileURLWithPath: "/usr"), timeout: .seconds(5)
        )
        #expect(result.stdout == "/custom/bin:/usr/bin\n/usr\n")
    }

    @Test func reportsExitCodeAndStderr() async {
        let result = await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo oops >&2; exit 3"], environment: [:], currentDirectory: tmp, timeout: .seconds(5))
        #expect(result.status == .exited(3))
        #expect(result.stderr == "oops\n")
        #expect(!result.succeeded)
    }

    @Test func missingExecutableFailsToStart() async {
        let result = await runner.run(URL(fileURLWithPath: "/nonexistent/claude"), [], environment: [:], currentDirectory: tmp, timeout: .seconds(5))
        guard case .failedToStart = result.status else {
            Issue.record("expected failedToStart, got \(result.status)")
            return
        }
    }

    @Test func searchPathKeepsAbsoluteEntriesAndAddsHomebrew() {
        #expect(CLILocator.searchPath(loginShellPATH: "/Users/x/.local/bin:relative:/usr/bin:/opt/homebrew/bin")
                == ["/Users/x/.local/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(CLILocator.searchPath(loginShellPATH: nil) == ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test func searchPathAddsTheHomeLocalBin() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        #expect(CLILocator.searchPath(loginShellPATH: "/usr/bin", home: home)
                == ["/usr/bin", "/Users/x/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(CLILocator.searchPath(loginShellPATH: "/Users/x/.local/bin", home: home)
                == ["/Users/x/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test func loginShellPATHIgnoresProfileOutput() async {
        let marker = CLILocator.pathMarker
        let runner = FakeRunner([CommandResult(status: .exited(0), stdout: "Welcome!\n\(marker)/a/bin:/usr/bin\(marker)bye\n", stderr: "")])
        let path = await CLILocator.loginShellPATH(runner: runner, home: tmp)
        #expect(path == "/a/bin:/usr/bin")
        #expect(runner.calls.first?.last?.contains(marker) == true)
        #expect(CLILocator.pathBetweenMarkers("no markers") == nil)
        #expect(CLILocator.pathBetweenMarkers("\(marker)\(marker)") == "")
    }

    @Test func aRunAfterStopAllDoesNotStart() async {
        let runner = ProcessCommandRunner()
        runner.stopAll()
        let start = Date()
        let result = await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], currentDirectory: tmp, timeout: .seconds(60))
        #expect(result.status == .stopped)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func aCancelledRunIsStopped() async {
        let runner = ProcessCommandRunner()
        let start = Date()
        let run = Task {
            await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], currentDirectory: tmp, timeout: .seconds(60))
        }
        run.cancel()
        #expect(await run.value.status == .stopped)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aClosedRegistryTakesNoGroup() {
        let registry = ProcessGroupRegistry()
        #expect(registry.add(999_999))
        #expect(!registry.isClosed)
        registry.stopAll(grace: .milliseconds(10))
        #expect(registry.isClosed)
        #expect(!registry.add(999_998))
        #expect(registry.remove(999_999))
    }
}
