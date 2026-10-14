import AppKit
import Foundation

/// MCPB manifest, version 0.3 (github.com/modelcontextprotocol/mcpb,
/// `@anthropic-ai/mcpb` 2.1.2). The schema is strict: only these keys.
struct MCPBManifest: Codable, Equatable {
    struct Author: Codable, Equatable {
        let name: String
        let url: String
    }

    struct Config: Codable, Equatable {
        let command: String
        let args: [String]
        let env: [String: String]
    }

    struct Server: Codable, Equatable {
        let type: String
        let entryPoint: String
        let mcpConfig: Config

        enum CodingKeys: String, CodingKey {
            case type
            case entryPoint = "entry_point"
            case mcpConfig = "mcp_config"
        }
    }

    struct Compatibility: Codable, Equatable {
        let platforms: [String]
    }

    struct ToolEntry: Codable, Equatable {
        let name: String
        let description: String
    }

    let manifestVersion: String
    let name: String
    let displayName: String
    let version: String
    let description: String
    let author: Author
    let homepage: String
    let license: String
    let icon: String
    let server: Server
    let tools: [ToolEntry]
    let compatibility: Compatibility

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name
        case displayName = "display_name"
        case version
        case description
        case author
        case homepage
        case license
        case icon
        case server
        case tools
        case compatibility
    }
}

protocol Archiver: Sendable {
    /// Zips `source` into `destination`. `keepParent` puts the folder itself
    /// in the zip; otherwise its contents are at the root.
    func zip(_ source: URL, keepParent: Bool, to destination: URL) throws
}

struct ArchiverError: Error, LocalizedError {
    let status: Int32
    var detail = ""
    var errorDescription: String? {
        let base = "Could not create the zip file (ditto exit code \(status))."
        return detail.isEmpty ? base : base + " " + detail
    }
}

/// `/usr/bin/ditto`, which keeps the executable bit and adds no resource
/// forks or extended attributes.
struct DittoArchiver: Archiver {
    func zip(_ source: URL, keepParent: Bool, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"]
            + (keepParent ? ["--keepParent"] : [])
            + [source.path, destination.path]
        process.standardInput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiverError(status: process.terminationStatus, detail: detail)
        }
    }
}

enum DesktopExtensionBuilder {
    static let manifestVersion = "0.3"
    static let entryPoint = "server/roger-mcp"

    static func manifest(executable: String, version: String) -> MCPBManifest {
        MCPBManifest(
            manifestVersion: manifestVersion,
            name: "roger",
            displayName: "Roger",
            version: version,
            description: "Log entries, meetings and file transcripts from Roger, with a change list so nothing is read twice.",
            author: .init(name: "Jordi Böhme", url: "https://github.com/jordiboehme"),
            homepage: "https://github.com/jordiboehme/roger",
            license: "MIT",
            icon: "icon.png",
            server: .init(
                type: "binary",
                entryPoint: entryPoint,
                mcpConfig: .init(command: executable, args: [], env: [:])
            ),
            tools: [
                .init(name: "status", description: "Library folder, item counts and consumers."),
                .init(name: "get_changes", description: "What changed since a consumer's bookmark, a time or a seq."),
                .init(name: "ack", description: "Moves a consumer's bookmark forward."),
                .init(name: "get_item", description: "One item as Markdown with its file paths."),
                .init(name: "list_items", description: "Current items, newest first."),
                .init(name: "search", description: "Items that contain every word of a query."),
            ],
            compatibility: .init(platforms: ["darwin"])
        )
    }

    /// The bundle's entry point: runs the `roger-mcp` inside Roger.app. The
    /// MCPB validator wants an executable file at `entry_point`.
    static func launcher(executable: String) -> String {
        "#!/bin/sh\nexec \(McpCommandFormatter.shellQuoted(executable)) \"$@\"\n"
    }

    /// `<folder>/roger.mcpb`, replaced when it exists (it is Roger's own temp file).
    static func buildExtension(executable: String, version: String, iconPNG: Data, in folder: URL, archiver: any Archiver) throws -> URL {
        let fm = FileManager.default
        let stage = folder.appendingPathComponent("roger-mcpb-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let server = stage.appendingPathComponent("server", isDirectory: true)
        try fm.createDirectory(at: server, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest(executable: executable, version: version)).write(to: stage.appendingPathComponent("manifest.json"))
        try iconPNG.write(to: stage.appendingPathComponent("icon.png"))
        let launcherURL = server.appendingPathComponent("roger-mcp")
        try Data(launcher(executable: executable).utf8).write(to: launcherURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

        // Zip next to the final name, then swap it in: Desktop never sees a half-written bundle.
        let output = folder.appendingPathComponent("roger.mcpb")
        let partial = folder.appendingPathComponent("roger-\(UUID().uuidString).mcpb")
        defer { try? fm.removeItem(at: partial) }
        try archiver.zip(stage, keepParent: false, to: partial)
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: output)
        }
        return output
    }

    /// `<folder>/ingest-roger.zip` holding `ingest-roger/SKILL.md`. Never
    /// overwrites: `ingest-roger 1.zip`, `ingest-roger 2.zip` …
    static func buildSkillZip(_ skill: BundledSkill, in folder: URL, archiver: any Archiver) throws -> URL {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("roger-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let skillFolder = stage.appendingPathComponent(BundledSkill.name, isDirectory: true)
        try fm.createDirectory(at: skillFolder, withIntermediateDirectories: true)
        try skill.content.write(to: skillFolder.appendingPathComponent("SKILL.md"))

        // Zip inside the staging folder, then move to a free name. The move
        // fails when the target exists, so a file is never overwritten.
        let partial = stage.appendingPathComponent("\(BundledSkill.name).zip")
        try archiver.zip(skillFolder, keepParent: true, to: partial)
        var counter = 0
        while true {
            let name = counter == 0 ? "\(BundledSkill.name).zip" : "\(BundledSkill.name) \(counter).zip"
            let output = folder.appendingPathComponent(name)
            if try moveWithoutReplacing(partial, to: output) { return output }
            counter += 1
            if counter > 1000 { throw CocoaError(.fileWriteFileExists) }
        }
    }

    /// Atomic move that never replaces: false when `destination` exists. Falls
    /// back to copy + remove across volumes, where the copy fails on a clash.
    private static func moveWithoutReplacing(_ source: URL, to destination: URL) throws -> Bool {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return true }
        switch errno {
        case EEXIST: return false
        case EXDEV:
            let fm = FileManager.default
            do {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: source)
                return true
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                return false
            }
        default:
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// The app icon as a `size` x `size` PNG.
    static func iconPNG(for appBundle: URL, size: Int = 256) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: appBundle.path)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// What Roger knows about Claude Desktop: only what it did itself.
struct DesktopRecord: Codable, Equatable, Sendable {
    var extensionCommand: String?
    var extensionAddedAt: Date?
    var skillSavedAt: Date?

    /// The extension points at another `roger-mcp` than the running app's.
    func appMoved(currentExecutable: String) -> Bool {
        guard let extensionCommand else { return false }
        return extensionCommand != currentExecutable
    }
}

/// `~/Library/Application Support/Roger/claude-desktop.json`.
struct DesktopRecordStore: Sendable {
    let fileURL: URL

    static var live: DesktopRecordStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return DesktopRecordStore(fileURL: support.appendingPathComponent("Roger/claude-desktop.json"))
    }

    func load() -> DesktopRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL), let record = try? decoder.decode(DesktopRecord.self, from: data) else {
            return DesktopRecord()
        }
        return record
    }

    func save(_ record: DesktopRecord) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: fileURL, options: .atomic)
    }
}
