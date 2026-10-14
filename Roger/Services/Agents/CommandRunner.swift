import Foundation

struct CommandResult: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case failedToStart(String)
    }

    let status: Status
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == .exited(0) }
}

protocol CommandRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String], currentDirectory: URL, timeout: Duration) async -> CommandResult
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
/// passed, and after `timeout` the process group gets SIGTERM, then SIGKILL.
struct ProcessCommandRunner: CommandRunner {
    /// How long a process may take to end after SIGTERM.
    static let terminationGrace: Duration = .seconds(1)
    /// How long to wait for the exit after SIGKILL.
    static let killWait: Duration = .seconds(2)

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
        let finishedInTime = await Self.waitForExit(process, timeout: timeout)
        if !finishedInTime {
            kill(-group, SIGTERM)
            let ended = await Self.waitForExit(process, timeout: Self.terminationGrace)
            // Children that ignore SIGTERM may outlive the leader, so the
            // group gets SIGKILL either way.
            kill(-group, SIGKILL)
            if !ended {
                _ = await Self.waitForExit(process, timeout: Self.killWait)
            }
        }
        // Give the handlers a moment for the last bytes, then stop reading.
        // A grandchild may hold the pipe open, so never read to end of file.
        try? await Task.sleep(for: .milliseconds(100))
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let status: CommandResult.Status = finishedInTime ? .exited(process.terminationStatus) : .timedOut
        return CommandResult(status: status, stdout: out.text, stderr: err.text)
    }

    /// True when the process ended within `timeout`. Polls, so no wait can
    /// outlive its deadline. A cancelled task stops waiting at once.
    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning {
            if Task.isCancelled || clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

/// Where harness CLIs are looked for: the login shell's `PATH` (a GUI app
/// gets a short one) plus Homebrew's folders.
enum CLILocator {
    static let extraDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func searchPath(loginShellPATH: String?) -> [String] {
        let fromShell = (loginShellPATH ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        return (fromShell + extraDirectories).filter { seen.insert($0).inserted }
    }

    static func find(_ name: String, in directories: [String]) -> URL? {
        directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `PATH` as the user's login shell sets it. Nil when the shell fails.
    static func loginShellPATH(runner: any CommandRunner, home: URL) async -> String? {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? "/bin/zsh"
        let result = await runner.run(
            URL(fileURLWithPath: shell),
            ["-l", "-c", "printf '%s' \"$PATH\""],
            environment: ["HOME": home.path, "USER": NSUserName()],
            currentDirectory: home,
            timeout: .seconds(5)
        )
        guard result.succeeded else { return nil }
        // Profile scripts may print first; PATH is the last line.
        return result.stdout.split(separator: "\n").last.map(String.init)
    }
}
