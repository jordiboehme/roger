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

    /// Script content: cd to the directory, delete itself, run the line.
    static func scriptContent(commandLine: String, workingDirectory: URL) -> String {
        "#!/bin/zsh -l\ncd \(CommandTemplate.shellQuote(workingDirectory.path)) || exit 1\nrm -f \"$0\"\n\(commandLine)\n"
    }

    /// Writes <temporaryDirectory>/roger-command-<uuid>.command with mode 0700.
    func writeScript(commandLine: String, workingDirectory: URL) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("roger-command-\(UUID().uuidString).command")
        let content = Self.scriptContent(commandLine: commandLine, workingDirectory: workingDirectory)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
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
        let name = "roger-command-\(UUID().uuidString)"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp/launch_configurations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let yamlURL = directory.appendingPathComponent("\(name).yaml")
        let yaml = """
        ---
        name: \(name)
        windows:
          - tabs:
              - layout:
                  cwd: \(Self.yamlQuote(workingDirectory.path))
                  commands:
                    - exec: \(Self.yamlQuote(CommandTemplate.shellQuote(script.path)))

        """
        try yaml.write(to: yamlURL, atomically: true, encoding: .utf8)
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            try? FileManager.default.removeItem(at: yamlURL)
        }
        guard let url = URL(string: "warp://launch/\(name)") else {
            throw TerminalLaunchError.launchFailed("Could not build the Warp launch URL.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened { throw TerminalLaunchError.launchFailed("Warp did not open the launch configuration.") }
    }

    /// YAML double-quoted scalar.
    private static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
