import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "Commands")

enum TerminalLaunchError: LocalizedError {
    case notInstalled(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let message), .launchFailed(let message): return message
        }
    }
}

/// Opens an interactive command in Terminal, iTerm2, Ghostty or Warp.
struct TerminalLauncher: TerminalLaunching {
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    /// Where Warp reads launch configurations.
    var warpConfigDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".warp/launch_configurations", isDirectory: true)

    /// Roger's launch configurations start with this.
    static let warpConfigPrefix = "roger-command-"
    /// Warp reads the configuration when it opens the URL. Older ones are
    /// left over (Roger quit before it removed them) and get removed.
    static let warpConfigLifetime: TimeInterval = 60

    /// Script content: cd to the directory, delete itself, run the line.
    static func scriptContent(commandLine: String, workingDirectory: URL) -> String {
        "#!/bin/zsh -l\ncd \(CommandTemplate.shellQuote(workingDirectory.path)) || exit 1\nrm -f \"$0\"\n\(commandLine)\n"
    }

    /// Writes <temporaryDirectory>/roger-command-<uuid>.command. The file
    /// is created with mode 0700, so it is never readable by others.
    func writeScript(commandLine: String, workingDirectory: URL) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("roger-command-\(UUID().uuidString).command")
        let content = Data(Self.scriptContent(commandLine: commandLine, workingDirectory: workingDirectory).utf8)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o700)
        guard descriptor >= 0 else {
            throw TerminalLaunchError.launchFailed("Could not write the script for the terminal: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: content)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    func launch(commandLine: String, workingDirectory: URL, terminal: TerminalApp) async throws {
        let appURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier)
        }
        guard let appURL else {
            throw TerminalLaunchError.notInstalled("\(terminal.displayName) is not installed.")
        }
        let script = try writeScript(commandLine: commandLine, workingDirectory: workingDirectory)
        do {
            switch terminal {
            case .terminal, .iterm2:
                try await Self.open(script, with: appURL)
            case .ghostty:
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = ["-e", script.path]
                config.createsNewApplicationInstance = true
                try await Self.openApp(appURL, config)
            case .warp:
                try await launchWarp(script: script, workingDirectory: workingDirectory)
            }
        } catch {
            try? FileManager.default.removeItem(at: script)
            if let error = error as? TerminalLaunchError { throw error }
            throw TerminalLaunchError.launchFailed(error.localizedDescription)
        }
    }

    @MainActor
    private static func open(_ file: URL, with appURL: URL) async throws {
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    private static func openApp(_ appURL: URL, _ config: NSWorkspace.OpenConfiguration) async throws {
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    private func launchWarp(script: URL, workingDirectory: URL) async throws {
        let name = Self.warpConfigPrefix + UUID().uuidString
        let directory = warpConfigDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.removeStaleWarpConfigs(in: directory, now: .now)
        let yamlURL = directory.appendingPathComponent("\(name).yaml")
        try Self.warpYAML(name: name, workingDirectory: workingDirectory, script: script)
            .write(to: yamlURL, atomically: true, encoding: .utf8)
        guard let url = URL(string: "warp://launch/\(name)") else {
            try? FileManager.default.removeItem(at: yamlURL)
            throw TerminalLaunchError.launchFailed("Could not build the Warp launch URL.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            try? FileManager.default.removeItem(at: yamlURL)
            throw TerminalLaunchError.launchFailed("Warp did not open the launch configuration.")
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            try? FileManager.default.removeItem(at: yamlURL)
        }
    }

    /// The launch configuration: one window in `workingDirectory` that runs `script`.
    static func warpYAML(name: String, workingDirectory: URL, script: URL) -> String {
        """
        ---
        name: \(name)
        windows:
          - tabs:
              - layout:
                  cwd: \(yamlQuote(workingDirectory.path))
                  commands:
                    - exec: \(yamlQuote(CommandTemplate.shellQuote(script.path)))

        """
    }

    /// Removes Roger's launch configurations older than `warpConfigLifetime`.
    static func removeStaleWarpConfigs(in directory: URL, now: Date) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(warpConfigPrefix) && name.hasSuffix(".yaml") {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > warpConfigLifetime
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// YAML double-quoted scalar.
    static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
