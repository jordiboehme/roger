import Foundation

enum HarnessID: String, CaseIterable, Codable, Sendable {
    case claudeCode
    case codex
    case gemini
    case cursor
    case copilot
    case kiro
}

/// One coding agent Roger knows. Paths are relative to the home folder.
/// Folders and CLIs were checked against each tool's docs on 2026-10-14
/// (see the plan's Verified facts). The config files were checked on
/// 2026-10-15 with codex 0.162.1, gemini 0.46.0, copilot 1.0.98 and
/// kiro-cli 2.31.1: `mcp add` writes them and `mcp list` reads them.
struct HarnessSpec: Equatable, Sendable {
    let id: HarnessID
    let name: String
    /// Detected when this folder exists.
    let homeFolder: String
    /// Every user-level skills folder the harness reads.
    let readsSkillFolders: [String]
    /// The folder Roger writes for it when no other row covers it.
    let writesSkillFolder: String
    /// Executable that registers MCP servers, nil when there is none.
    let cli: String?
    /// Config files Roger reads (never writes) to show the server state.
    let configFiles: [String]

    /// The config files as URLs. Codex reads its config from `CODEX_HOME`
    /// when the login shell sets it, else from `~/.codex`.
    func configURLs(home: URL, codexHome: String?) -> [URL] {
        guard id == .codex else { return configFiles.map { home.appendingPathComponent($0) } }
        switch Self.codexHome(codexHome, home: home) {
        case .standard: return configFiles.map { home.appendingPathComponent($0) }
        case .folder(let folder): return [folder.appendingPathComponent("config.toml")]
        case .unusable: return []
        }
    }

    /// Where Codex keeps its files, as Codex 0.162.1 reads `CODEX_HOME`.
    enum CodexHome: Equatable, Sendable {
        /// Not set (or empty): `~/.codex`.
        case standard
        case folder(URL)
        /// Codex refuses it (it does not expand `~`), so it has no config.
        case unusable
    }

    /// An absolute value is used as it is. A relative one is resolved
    /// against the working directory Codex runs in, which is the home
    /// folder for Roger's registrations and suggested commands.
    static func codexHome(_ value: String?, home: URL) -> CodexHome {
        guard let value, !value.isEmpty else { return .standard }
        if value.hasPrefix("~") { return .unusable }
        if value.hasPrefix("/") { return .folder(URL(fileURLWithPath: value, isDirectory: true)) }
        return .folder(home.appendingPathComponent(value, isDirectory: true))
    }
}

enum HarnessCatalog {
    /// In this order: the first harness that writes a folder owns it.
    static let all: [HarnessSpec] = [
        HarnessSpec(id: .claudeCode, name: "Claude Code", homeFolder: ".claude",
                    readsSkillFolders: [".claude/skills"], writesSkillFolder: ".claude/skills",
                    cli: "claude", configFiles: [".claude.json"]),
        HarnessSpec(id: .codex, name: "Codex", homeFolder: ".codex",
                    readsSkillFolders: [".agents/skills", ".codex/skills"], writesSkillFolder: ".agents/skills",
                    cli: "codex", configFiles: [".codex/config.toml"]),
        HarnessSpec(id: .gemini, name: "Gemini CLI", homeFolder: ".gemini",
                    readsSkillFolders: [".agents/skills", ".gemini/skills"], writesSkillFolder: ".agents/skills",
                    cli: "gemini", configFiles: [".gemini/settings.json"]),
        HarnessSpec(id: .cursor, name: "Cursor", homeFolder: ".cursor",
                    readsSkillFolders: [".agents/skills", ".cursor/skills", ".claude/skills", ".codex/skills"], writesSkillFolder: ".agents/skills",
                    cli: nil, configFiles: [".cursor/mcp.json"]),
        HarnessSpec(id: .copilot, name: "Copilot CLI", homeFolder: ".copilot",
                    readsSkillFolders: [".agents/skills", ".copilot/skills"], writesSkillFolder: ".agents/skills",
                    cli: "copilot", configFiles: [".copilot/mcp-config.json"]),
        HarnessSpec(id: .kiro, name: "Kiro", homeFolder: ".kiro",
                    readsSkillFolders: [".kiro/skills"], writesSkillFolder: ".kiro/skills",
                    cli: "kiro-cli", configFiles: [".kiro/settings/mcp.json"]),
    ]

    static func spec(_ id: HarnessID) -> HarnessSpec {
        all.first { $0.id == id }!
    }

    /// The only folders Roger ever writes `ingest-roger/` into.
    static var knownSkillFolders: [String] {
        Array(Set(all.map(\.writesSkillFolder))).sorted()
    }

    /// Harnesses whose home folder exists in `home` (a folder, not a file).
    /// Codex also counts when the `CODEX_HOME` folder exists.
    static func detected(home: URL, codexHome: String? = nil) -> [HarnessSpec] {
        all.filter { spec in
            if isFolder(home.appendingPathComponent(spec.homeFolder)) { return true }
            if spec.id == .codex, case .folder(let folder) = HarnessSpec.codexHome(codexHome, home: home) {
                return isFolder(folder)
            }
            return false
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

struct HarnessInstallPlan: Equatable, Sendable {
    let harness: HarnessSpec
    /// The skills folder that holds (or will hold) `ingest-roger/`.
    let skillFolder: URL
    /// Another row writes a folder this harness reads; this row writes nothing.
    let coveredBy: HarnessID?
}

enum SkillInstallPlanner {
    /// In catalog order: a harness that reads a folder an earlier row writes
    /// is covered by that row; otherwise it writes its own folder.
    static func plan(for harnesses: [HarnessSpec], home: URL) -> [HarnessInstallPlan] {
        var written: [(folder: String, by: HarnessID)] = []
        var plans: [HarnessInstallPlan] = []
        for harness in harnesses {
            if let cover = written.first(where: { harness.readsSkillFolders.contains($0.folder) }) {
                plans.append(HarnessInstallPlan(harness: harness, skillFolder: home.appendingPathComponent(cover.folder, isDirectory: true), coveredBy: cover.by))
            } else {
                written.append((harness.writesSkillFolder, harness.id))
                plans.append(HarnessInstallPlan(harness: harness, skillFolder: home.appendingPathComponent(harness.writesSkillFolder, isDirectory: true), coveredBy: nil))
            }
        }
        return plans
    }
}
