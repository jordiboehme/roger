import AppKit
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AppRelauncher")

/// "Relaunch Roger" is a quit with a relaunch after it. The quit asks
/// about unsaved edits first; only when Roger may quit does the helper
/// start, so the question and the helper never run at the same time.
struct RelaunchGate: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Quit, nothing else.
        case quit
        /// Start the helper, then quit.
        case relaunch
        /// The user cancelled (or the save failed): stay and forget the relaunch.
        case stay
    }

    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    /// After the unsaved-edit question. `mayQuit` is false for Cancel or a
    /// failed save.
    mutating func decide(mayQuit: Bool) -> Decision {
        defer { isPending = false }
        guard mayQuit else { return .stay }
        return isPending ? .relaunch : .quit
    }
}

/// Relaunches Roger. This is the reliable fix for a process-scoped CoreAudio
/// wedge (macOS 26.5.x can stop delivering input buffers to a long-lived
/// audio client; only a fresh process gets a fresh HAL connection). A helper
/// shell opens the bundle again once this process is gone.
@MainActor
enum AppRelauncher {
    private static var gate = RelaunchGate()

    /// Goes through the normal quit, so `applicationShouldTerminate` asks
    /// about unsaved edits first.
    static func relaunch() {
        gate.request()
        NSApp.terminate(nil)
    }

    /// The answer for `applicationShouldTerminate`, after the unsaved-edit
    /// question.
    static func terminateReply(mayQuit: Bool) -> NSApplication.TerminateReply {
        switch gate.decide(mayQuit: mayQuit) {
        case .stay:
            return .terminateCancel
        case .quit:
            return .terminateNow
        case .relaunch:
            // Without the helper a quit would just close Roger: stay instead.
            return startHelper() ? .terminateNow : .terminateCancel
        }
    }

    /// Waits until process `pid` is gone, then opens the app.
    nonisolated static func helperScript(pid: Int32, bundlePath: String) -> String {
        waitLoop(pid: pid) + "; /usr/bin/open " + McpCommandFormatter.shellQuoted(bundlePath)
    }

    /// Shell code that returns once process `pid` is gone.
    nonisolated static func waitLoop(pid: Int32) -> String {
        "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done"
    }

    private static func startHelper() -> Bool {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", helperScript(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)]
        do {
            try helper.run()
            return true
        } catch {
            logger.error("Relaunch helper did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
