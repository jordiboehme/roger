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
}
