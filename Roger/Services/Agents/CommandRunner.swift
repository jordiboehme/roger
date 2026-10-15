import Foundation

struct CommandResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case failedToStart(String)
        /// `stopAll()` ended it (Roger quits) or its task was cancelled.
        case stopped
    }

    let status: Status
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == .exited(0) }
}

protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult
    /// Ends every run that is still going. Returns once they got SIGKILL
    /// or ended. Roger calls it when it quits.
    func stopAll()
}

extension CommandRunner {
    func stopAll() {}
}

/// The process groups of the runs that are going, so a quit can end them
/// without waiting for their tasks. After `stopAll` it is closed: no new
/// group is taken, so a run that starts during the quit stops at once.
final class ProcessGroupRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: Set<pid_t> = []
    private var stopped: Set<pid_t> = []
    private var closed = false

    /// True once `stopAll` ran.
    var isClosed: Bool { lock.withLock { closed } }

    /// Takes `group`. False when the registry is closed: the caller must
    /// end the group itself.
    func add(_ group: pid_t) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            groups.insert(group)
            return true
        }
    }

    /// Forgets `group`. True when `stopAll` ended it.
    func remove(_ group: pid_t) -> Bool {
        lock.withLock {
            groups.remove(group)
            return stopped.remove(group) != nil
        }
    }

    /// SIGTERM to every group, up to `grace` for them to end, then SIGKILL.
    /// Blocks the caller for at most `grace`.
    func stopAll(grace: Duration) {
        let targets = lock.withLock {
            closed = true
            stopped.formUnion(groups)
            return groups
        }
        guard !targets.isEmpty else { return }
        for group in targets { kill(-group, SIGTERM) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: grace)
        // kill(-group, 0) fails once no process of the group is left.
        while clock.now < deadline, targets.contains(where: { kill(-$0, 0) == 0 }) {
            usleep(20_000)
        }
        for group in targets { kill(-group, SIGKILL) }
    }
}

/// Collects a pipe's output from its readability handler.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    /// Reads until end of file, then stops the handler (it would spin at EOF).
    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                append(chunk)
            }
        }
    }
}

/// Runs a harness CLI so that it can never block Roger: stdin is
/// `/dev/null` (a prompt reads end of file), only the given environment is
/// passed, and after `timeout` (or when its task is cancelled) the process
/// group gets SIGTERM, then SIGKILL. `stopAll()` does the same for every run.
struct ProcessCommandRunner: CommandRunner {
    /// How long a process may take to end after SIGTERM.
    static let terminationGrace: Duration = .seconds(1)
    /// How long to wait for the exit after SIGKILL.
    static let killWait: Duration = .seconds(2)

    let registry = ProcessGroupRegistry()

    func stopAll() {
        registry.stopAll(grace: Self.terminationGrace)
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = OutputBuffer()
        let err = OutputBuffer()
        out.attach(to: outPipe)
        err.attach(to: errPipe)

        // Roger quits or the run was cancelled: do not start it.
        if Task.isCancelled || registry.isClosed {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: .stopped, stdout: "", stderr: "")
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: .failedToStart(error.localizedDescription), stdout: "", stderr: "")
        }

        // Process starts the child as the leader of its own process group,
        // so a signal to the group also reaches what the CLI started.
        let group = process.processIdentifier
        guard registry.add(group) else {
            // stopAll ran while this run started: end it at once.
            kill(-group, SIGKILL)
            _ = await Self.waitForExit(process, timeout: Self.killWait, stopsOnCancel: false)
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: .stopped, stdout: out.text, stderr: err.text)
        }
        let finishedInTime = await Self.waitForExit(process, timeout: timeout, stopsOnCancel: true)
        if !finishedInTime {
            kill(-group, SIGTERM)
            // A cancelled run still gets its grace time before SIGKILL.
            let ended = await Self.waitForExit(process, timeout: Self.terminationGrace, stopsOnCancel: false)
            // Children that ignore SIGTERM may outlive the leader, so the
            // group gets SIGKILL either way.
            kill(-group, SIGKILL)
            if !ended {
                _ = await Self.waitForExit(process, timeout: Self.killWait, stopsOnCancel: false)
            }
        }
        let stoppedByStopAll = registry.remove(group)
        // Give the handlers a moment for the last bytes, then stop reading.
        // A grandchild may hold the pipe open, so never read to end of file.
        try? await Task.sleep(for: .milliseconds(100))
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let status: CommandResult.Status
        if stoppedByStopAll || Task.isCancelled {
            status = .stopped
        } else {
            status = finishedInTime ? .exited(process.terminationStatus) : .timedOut
        }
        return CommandResult(status: status, stdout: out.text, stderr: err.text)
    }

    /// True when the process ended within `timeout`. Polls, so no wait can
    /// outlive its deadline. With `stopsOnCancel`, a cancelled task stops
    /// waiting at once.
    private static func waitForExit(_ process: Process, timeout: Duration, stopsOnCancel: Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            if (stopsOnCancel && Task.isCancelled) || clock.now >= deadline { return false }
            await pause(milliseconds: 20)
        }
        return true
    }

    /// Waits also in a cancelled task, where `Task.sleep` returns at once.
    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}

/// Where harness CLIs are looked for: the login shell's `PATH` (a GUI app
/// gets a short one), `~/.local/bin` (the native Claude Code installer)
/// and Homebrew's folders.
enum CLILocator {
    static let extraDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// Relative to the home folder.
    static let homeDirectories = [".local/bin"]
    /// Printed around `PATH`, so profile output before or after it is ignored.
    static let pathMarker = "__ROGER_PATH__"

    static func searchPath(loginShellPATH: String?, home: URL? = nil) -> [String] {
        let fromShell = (loginShellPATH ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        let fromHome = home.map { home in homeDirectories.map { home.appendingPathComponent($0).path } } ?? []
        var seen = Set<String>()
        return (fromShell + fromHome + extraDirectories).filter { seen.insert($0).inserted }
    }

    static func find(_ name: String, in directories: [String]) -> URL? {
        directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The user's login shell from the user database, `/bin/zsh` when it
    /// has none.
    static var loginShell: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// Printed around `CODEX_HOME`.
    static let codexHomeMarker = "__ROGER_CODEX_HOME__"

    /// What Roger reads from the login shell's environment.
    struct LoginShellEnvironment: Equatable, Sendable {
        var path: String
        /// Nil when the shell does not set it.
        var codexHome: String?
    }

    /// `PATH` as the user's login shell sets it. Nil when the shell fails.
    static func loginShellPATH(runner: any CommandRunner, home: URL) async -> String? {
        await loginShellEnvironment(runner: runner, home: home)?.path
    }

    /// `PATH` and `CODEX_HOME` as the user's login shell sets them, in one
    /// call. Nil when the shell fails.
    static func loginShellEnvironment(runner: any CommandRunner, home: URL) async -> LoginShellEnvironment? {
        let script = "printf '\(pathMarker)%s\(pathMarker)' \"$PATH\"; "
            + "printf '\(codexHomeMarker)%s\(codexHomeMarker)' \"${CODEX_HOME:-}\""
        let result = await runner.run(
            URL(fileURLWithPath: loginShell),
            ["-l", "-c", script],
            environment: ["HOME": home.path, "USER": NSUserName()],
            currentDirectory: home,
            timeout: .seconds(5)
        )
        guard result.succeeded else { return nil }
        return environment(fromOutput: result.stdout)
    }

    /// Reads the marked values. Nil when the `PATH` markers are missing.
    static func environment(fromOutput output: String) -> LoginShellEnvironment? {
        guard let path = pathBetweenMarkers(output) else { return nil }
        let codexHome = between(codexHomeMarker, in: output).flatMap { $0.isEmpty ? nil : $0 }
        return LoginShellEnvironment(path: path, codexHome: codexHome)
    }

    /// The text between the first two markers. Nil when they are missing.
    static func pathBetweenMarkers(_ output: String) -> String? {
        between(pathMarker, in: output)
    }

    private static func between(_ marker: String, in output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        return parts[1]
    }
}
