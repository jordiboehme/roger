import Foundation
import Testing
@testable import Roger

/// Records what went to the "Trash" and moves it into a temp folder.
final class TrashSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var moved: [URL] = []
    let folder: URL

    init(folder: URL) { self.folder = folder }

    var urls: [URL] { lock.withLock { moved } }

    func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(UUID().uuidString))
        lock.withLock { moved.append(url) }
    }
}

struct SkillInstallerTests {
    private let v1 = BundledSkill(content: Data("---\nname: ingest-roger\n---\nversion one\n".utf8), version: "0.25.0")
    private let v2 = BundledSkill(content: Data("---\nname: ingest-roger\n---\nversion two\n".utf8), version: "0.26.0")

    private func installer(_ home: URL, _ skill: BundledSkill, trash: TrashSpy? = nil) -> SkillInstaller {
        let spy = trash ?? TrashSpy(folder: home.appendingPathComponent("Trash"))
        return SkillInstaller(
            home: home,
            receiptURL: home.appendingPathComponent("Library/Application Support/Roger/skill-installs.json"),
            skill: skill,
            trash: { try spy.trash($0) },
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    private func makeHome(_ folders: [String]) throws -> URL {
        let home = try TempFolder.make()
        for folder in folders {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        return home
    }

    private func claudeSkills(_ home: URL) -> URL { home.appendingPathComponent(".claude/skills", isDirectory: true) }

    @Test func detectsHarnessesByHomeFolder() throws {
        let home = try makeHome([".claude", ".gemini", ".kiro"])
        defer { TempFolder.remove(home) }
        try Data().write(to: home.appendingPathComponent(".codex"))
        #expect(HarnessCatalog.detected(home: home).map(\.id) == [.claudeCode, .gemini, .kiro])
    }

    @Test func sharedFoldersAreWrittenOnce() throws {
        let home = try makeHome([".claude", ".codex", ".gemini", ".cursor", ".copilot", ".kiro"])
        defer { TempFolder.remove(home) }
        let plan = SkillInstallPlanner.plan(for: HarnessCatalog.detected(home: home), home: home)
        let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.harness.id, $0) })
        #expect(byID[.claudeCode]?.coveredBy == nil)
        #expect(byID[.claudeCode]?.skillFolder.path == home.appendingPathComponent(".claude/skills").path)
        #expect(byID[.codex]?.coveredBy == nil)
        #expect(byID[.codex]?.skillFolder.path == home.appendingPathComponent(".agents/skills").path)
        #expect(byID[.gemini]?.coveredBy == .codex)
        #expect(byID[.copilot]?.coveredBy == .codex)
        #expect(byID[.cursor]?.coveredBy == .claudeCode)
        #expect(byID[.kiro]?.coveredBy == nil)
        #expect(byID[.kiro]?.skillFolder.path == home.appendingPathComponent(".kiro/skills").path)
    }

    @Test func cursorAloneWritesTheAgentsFolder() throws {
        let home = try makeHome([".cursor"])
        defer { TempFolder.remove(home) }
        let plan = SkillInstallPlanner.plan(for: HarnessCatalog.detected(home: home), home: home)
        #expect(plan.map(\.coveredBy) == [nil])
        #expect(plan.first?.skillFolder.path == home.appendingPathComponent(".agents/skills").path)
    }

    @Test func statesFollowContentAndReceipt() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let folder = claudeSkills(home)
        #expect(installer(home, v1).state(of: folder) == .notInstalled)
        #expect(try installer(home, v1).install(into: folder) == .installed)
        #expect(installer(home, v1).state(of: folder) == .upToDate)
        #expect(installer(home, v2).state(of: folder) == .outdated)
        #expect(installer(home, v2).anyOutdated())
        #expect(try Data(contentsOf: installer(home, v1).skillFile(in: folder)) == v1.content)
    }

    @Test func changedByYouWinsOverOutdated() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let folder = claudeSkills(home)
        try installer(home, v1).install(into: folder)
        try Data("my own notes\n".utf8).write(to: installer(home, v1).skillFile(in: folder))
        #expect(installer(home, v1).state(of: folder) == .changedByYou)
        #expect(installer(home, v2).state(of: folder) == .changedByYou)
    }

    @Test func aMatchingFileWithoutReceiptIsAdopted() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let file = installer(home, v1).skillFile(in: claudeSkills(home))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try v1.content.write(to: file)
        #expect(installer(home, v1).state(of: claudeSkills(home)) == .upToDate)
        try Data("other".utf8).write(to: file)
        #expect(installer(home, v1).state(of: claudeSkills(home)) == .changedByYou)
    }

    @Test func secondUpdateKeepsTheFirstBackup() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let folder = claudeSkills(home)
        let file = installer(home, v1).skillFile(in: folder)
        try installer(home, v1).install(into: folder)
        try Data("first edit\n".utf8).write(to: file)
        #expect(try installer(home, v2).install(into: folder) == .updated(backup: file.deletingLastPathComponent().appendingPathComponent("SKILL.md.bak")))
        try Data("second edit\n".utf8).write(to: file)
        #expect(try installer(home, v2).install(into: folder) == .updated(backup: file.deletingLastPathComponent().appendingPathComponent("SKILL.md.bak 1")))
        let skillFolder = file.deletingLastPathComponent()
        #expect(try String(contentsOf: skillFolder.appendingPathComponent("SKILL.md.bak"), encoding: .utf8) == "first edit\n")
        #expect(try String(contentsOf: skillFolder.appendingPathComponent("SKILL.md.bak 1"), encoding: .utf8) == "second edit\n")
        #expect(try Data(contentsOf: file) == v2.content)
        #expect(installer(home, v2).state(of: folder) == .upToDate)
    }

    @Test func plainUpdateMakesNoBackup() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let folder = claudeSkills(home)
        try installer(home, v1).install(into: folder)
        #expect(try installer(home, v2).install(into: folder) == .updated(backup: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: installer(home, v2).skillFile(in: folder).deletingLastPathComponent().path)
        #expect(names == ["SKILL.md"])
    }

    @Test func uninstallAsksForAChangedFileAndThenUsesTheTrash() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let spy = TrashSpy(folder: home.appendingPathComponent("Trash"))
        let folder = claudeSkills(home)
        try installer(home, v1, trash: spy).install(into: folder)
        let file = installer(home, v1).skillFile(in: folder)
        try Data("mine\n".utf8).write(to: file)
        #expect(try installer(home, v1, trash: spy).uninstall(from: folder, confirmChanged: false) == .needsConfirmation)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try installer(home, v1, trash: spy).uninstall(from: folder, confirmChanged: true) == .movedToTrash)
        #expect(spy.urls.map(\.lastPathComponent) == ["SKILL.md"])
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test func uninstallKeepsOtherFilesTheUserAdded() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let folder = claudeSkills(home)
        try installer(home, v1).install(into: folder)
        let skillFolder = installer(home, v1).skillFile(in: folder).deletingLastPathComponent()
        try Data("x".utf8).write(to: skillFolder.appendingPathComponent("notes.txt"))
        #expect(try installer(home, v1).uninstall(from: folder, confirmChanged: false) == .removed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: skillFolder.path) == ["notes.txt"])
        #expect(installer(home, v1).loadReceipt().installs.isEmpty)
    }

    @Test func receiptEntriesOutsideKnownFoldersAreIgnored() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let evil = home.appendingPathComponent("Documents/important", isDirectory: true)
        let evilFile = evil.appendingPathComponent("ingest-roger/SKILL.md")
        try FileManager.default.createDirectory(at: evilFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try v1.content.write(to: evilFile)
        let receiptURL = home.appendingPathComponent("Library/Application Support/Roger/skill-installs.json")
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let receipt = SkillReceipt(version: 1, installs: [evil.path: .init(appVersion: "0.25.0", sha256: v1.sha256, installedAt: Date())])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: receiptURL)

        #expect(installer(home, v1).loadReceipt().installs.isEmpty)
        #expect(throws: SkillInstallError.unknownFolder(evil.path)) {
            try installer(home, v1).uninstall(from: evil, confirmChanged: true)
        }
        #expect(throws: SkillInstallError.unknownFolder(evil.path)) {
            try installer(home, v1).install(into: evil)
        }
        try installer(home, v1).install(into: claudeSkills(home))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(SkillReceipt.self, from: Data(contentsOf: receiptURL))
        #expect(Array(saved.installs.keys) == [claudeSkills(home).standardizedFileURL.path])
        #expect(FileManager.default.fileExists(atPath: evilFile.path))
    }

    @Test func aLinkedSkillFolderIsRefused() throws {
        let home = try makeHome([".claude/skills"])
        defer { TempFolder.remove(home) }
        let elsewhere = home.appendingPathComponent("dotfiles/ingest-roger", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = claudeSkills(home).appendingPathComponent("ingest-roger")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        #expect(throws: SkillInstallError.symbolicLink(link.path)) {
            try installer(home, v1).install(into: claudeSkills(home))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func corruptReceiptCountsAsEmpty() throws {
        let home = try makeHome([".claude"])
        defer { TempFolder.remove(home) }
        let receiptURL = home.appendingPathComponent("Library/Application Support/Roger/skill-installs.json")
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: receiptURL)
        #expect(installer(home, v1).loadReceipt().installs.isEmpty)
        #expect(try installer(home, v1).install(into: claudeSkills(home)) == .installed)
    }
}
