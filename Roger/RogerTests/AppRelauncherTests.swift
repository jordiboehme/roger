import Foundation
import Testing
@testable import Roger

struct AppRelauncherTests {
    @Test func relaunchWaitsForTheQuitQuestion() {
        var gate = RelaunchGate()
        gate.request()
        #expect(gate.isPending)
        #expect(gate.decide(mayQuit: true) == .relaunch)
        #expect(!gate.isPending)
    }

    @Test func aCancelledQuitForgetsTheRelaunch() {
        var gate = RelaunchGate()
        gate.request()
        #expect(gate.decide(mayQuit: false) == .stay)
        // A later normal quit does not relaunch.
        #expect(gate.decide(mayQuit: true) == .quit)
    }

    @Test func aPlainQuitDoesNotRelaunch() {
        var gate = RelaunchGate()
        #expect(gate.decide(mayQuit: true) == .quit)
    }

    @Test func theHelperWaitsForThisProcessAndQuotesThePath() {
        #expect(AppRelauncher.helperScript(pid: 4242, bundlePath: "/Applications/Roger.app")
            == "while /bin/kill -0 4242 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open /Applications/Roger.app")
        #expect(AppRelauncher.helperScript(pid: 7, bundlePath: "/Users/x/My Apps/Rog'er.app")
            .hasSuffix("; /usr/bin/open '/Users/x/My Apps/Rog'\\''er.app'"))
    }

    /// The loop really waits: with a live pid the shell is still running
    /// after a moment, and it ends right after that process is gone.
    @Test func theWaitLoopEndsWhenTheProcessIsGone() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Only the wait loop: never run `open` in a test.
        waiter.arguments = ["-c", AppRelauncher.waitLoop(pid: sleeper.processIdentifier)]
        try waiter.run()
        try await Task.sleep(for: .milliseconds(400))
        #expect(waiter.isRunning)
        sleeper.terminate()
        sleeper.waitUntilExit()
        for _ in 0..<50 where waiter.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!waiter.isRunning)
    }
}
