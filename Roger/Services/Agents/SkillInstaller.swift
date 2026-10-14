import Foundation

enum SkillRowState: Equatable, Sendable {
    case notInstalled
    case upToDate
    case outdated
    case changedByYou
}

/// `~/Library/Application Support/Roger/skill-installs.json`. Untrusted:
/// only entries for the known skills folders are used or kept.
struct SkillReceipt: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var appVersion: String
        var sha256: String
        var installedAt: Date
    }

    var version: Int = 1
    /// Key: standardized absolute path of the skills folder.
    var installs: [String: Entry] = [:]
}

enum SkillInstallOutcome: Equatable, Sendable {
    case installed
    /// `backup` is where a file you changed was saved first.
    case updated(backup: URL?)
}

enum SkillUninstallOutcome: Equatable, Sendable {
    case notInstalled
    case removed
    /// The file was changed by the user; ask, then call again with `confirmChanged`.
    case needsConfirmation
    case movedToTrash
}

enum SkillInstallError: Error, Equatable, LocalizedError {
    case unknownFolder(String)
    case symbolicLink(String)
    case notAFile(String)

    var errorDescription: String? {
        switch self {
        case .unknownFolder(let path):
            return "Roger only installs its skill in the skills folders of known agents, not in \(path)."
        case .notAFile(let path):
            return "\(path) is not a regular file. Roger leaves it alone."
        case .symbolicLink(let path):
            return "\(path) is a link. Roger does not write through links. Remove the link and try again."
        }
    }
}

/// Copies (never links) `ingest-roger/SKILL.md` into a skills folder with a
/// temp file plus rename, remembers what it wrote in the receipt and never
/// destroys a file the user changed.
struct SkillInstaller: Sendable {
    static let fileName = "SKILL.md"

    let home: URL
    let receiptURL: URL
    let skill: BundledSkill
    private let trash: @Sendable (URL) throws -> Void
    private let now: @Sendable () -> Date

    init(home: URL, receiptURL: URL, skill: BundledSkill, trash: @escaping @Sendable (URL) throws -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.receiptURL = receiptURL
        self.skill = skill
        self.trash = trash
        self.now = now
    }

    /// The installer for this Mac's real home folder and receipt.
    static func live(skill: BundledSkill) -> SkillInstaller {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return SkillInstaller(
            home: FileManager.default.homeDirectoryForCurrentUser,
            receiptURL: support.appendingPathComponent("Roger/skill-installs.json"),
            skill: skill,
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        )
    }

    var knownFolders: [URL] {
        HarnessCatalog.knownSkillFolders.map { home.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
    }

    func skillFile(in folder: URL) -> URL {
        folder.appendingPathComponent(BundledSkill.name, isDirectory: true).appendingPathComponent(Self.fileName)
    }

    func state(of folder: URL) -> SkillRowState {
        guard isKnown(folder), let data = regularFileData(skillFile(in: folder)) else { return .notInstalled }
        let hash = SkillHash.sha256(data)
        if let entry = loadReceipt().installs[key(folder)] {
            if hash != entry.sha256 { return .changedByYou }
            return hash == skill.sha256 ? .upToDate : .outdated
        }
        return hash == skill.sha256 ? .upToDate : .changedByYou
    }

    func anyOutdated() -> Bool {
        knownFolders.contains { state(of: $0) == .outdated }
    }

    @discardableResult
    func install(into folder: URL) throws -> SkillInstallOutcome {
        try requireKnown(folder)
        let skillFolder = skillFile(in: folder).deletingLastPathComponent()
        try refuseLink(skillFolder)
        let file = skillFile(in: folder)
        try refuseLink(file)
        try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)

        let existed = FileManager.default.fileExists(atPath: file.path)
        var backup: URL?
        if existed, state(of: folder) == .changedByYou {
            let target = freeBackupURL(in: skillFolder)
            try FileManager.default.moveItem(at: file, to: target)
            backup = target
        }
        let temp = skillFolder.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        do {
            try skill.content.write(to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, file.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        var receipt = loadReceipt()
        receipt.installs[key(folder)] = .init(appVersion: skill.version, sha256: skill.sha256, installedAt: now())
        try save(receipt)
        return existed ? .updated(backup: backup) : .installed
    }

    func uninstall(from folder: URL, confirmChanged: Bool) throws -> SkillUninstallOutcome {
        try requireKnown(folder)
        let skillFolder = skillFile(in: folder).deletingLastPathComponent()
        try refuseLink(skillFolder)
        let file = skillFile(in: folder)
        try refuseLink(file)
        var receipt = loadReceipt()
        guard FileManager.default.fileExists(atPath: file.path) else {
            receipt.installs[key(folder)] = nil
            try save(receipt)
            return .notInstalled
        }
        guard regularFileData(file) != nil else { throw SkillInstallError.notAFile(file.path) }
        let outcome: SkillUninstallOutcome
        if state(of: folder) == .changedByYou {
            guard confirmChanged else { return .needsConfirmation }
            try trash(file)
            outcome = .movedToTrash
        } else {
            guard unlink(file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            outcome = .removed
        }
        // rmdir only removes an empty folder, so nothing that landed there meanwhile is lost.
        if rmdir(skillFolder.path) != 0, errno != ENOTEMPTY, errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        receipt.installs[key(folder)] = nil
        try save(receipt)
        return outcome
    }

    /// The receipt with every entry outside the known folders dropped.
    /// Missing or broken: empty.
    func loadReceipt() -> SkillReceipt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: receiptURL),
              var receipt = try? decoder.decode(SkillReceipt.self, from: data)
        else { return SkillReceipt() }
        let allowed = Set(knownFolders.map(\.path))
        receipt.installs = receipt.installs.filter { allowed.contains($0.key) }
        return receipt
    }

    // MARK: - Helpers

    private func key(_ folder: URL) -> String {
        folder.standardizedFileURL.path
    }

    private func isKnown(_ folder: URL) -> Bool {
        knownFolders.map(\.path).contains(key(folder))
    }

    private func requireKnown(_ folder: URL) throws {
        guard isKnown(folder) else { throw SkillInstallError.unknownFolder(folder.path) }
    }

    private func refuseLink(_ url: URL) throws {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw SkillInstallError.symbolicLink(url.path) }
    }

    private func regularFileData(_ url: URL) -> Data? {
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        guard type == .typeRegular else { return nil }
        return try? Data(contentsOf: url)
    }

    /// `SKILL.md.bak`, then `SKILL.md.bak 1`, `SKILL.md.bak 2` … Never an existing name.
    private func freeBackupURL(in folder: URL) -> URL {
        let base = Self.fileName + ".bak"
        var candidate = folder.appendingPathComponent(base)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }

    private func save(_ receipt: SkillReceipt) throws {
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
    }
}
