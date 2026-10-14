import Foundation
@testable import RogerKit

/// Minimal files in the shape Roger writes them (the app's writers import
/// FluidAudio, so RogerKitTests cannot call them).
enum KitFixtures {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func stem(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// `<root>/Logs/YYYY/MM/<stem>.md`, optionally with `<stem>.m4a`.
    @discardableResult
    static func log(in layout: LibraryLayout, at date: Date, text: String, audio: Bool = false) throws -> URL {
        let folder = layout.monthFolder(.logs, for: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = stem(date)
        var sources = ""
        if audio {
            try Data("m4a".utf8).write(to: folder.appendingPathComponent(name + ".m4a"))
            sources = "sources:\n  - { id: audio, resource: \"\(name).m4a\" }\n"
        }
        let md = folder.appendingPathComponent(name + ".md")
        let body = "---\ntype: source\ntitle: \"Log \(name)\"\ntags: [log]\n\(sources)status: stable\nstarted_at: \(iso(date))\nduration_seconds: 12\n---\n# Log \(name)\n\n\(text)\n"
        try body.write(to: md, atomically: true, encoding: .utf8)
        return md
    }

    /// A finished meeting session `<parent>/<name>/` with `transcript.md`,
    /// `mic.m4a` and optionally one screenshot. Returns the session folder.
    @discardableResult
    static func meeting(in parent: URL, name: String, at date: Date, text: String, screenshot: Bool = false) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: folder.appendingPathComponent("mic.m4a"))
        if screenshot {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("\(stem(date)).png"))
        }
        let body = "---\ntype: source\ntitle: \"Meeting \(name)\"\ntags: [meeting, transcript]\nsources:\n  - { id: mic, resource: \"mic.m4a\" }\nstatus: stable\nstarted_at: \(iso(date))\nduration_seconds: 600\nspeaker_count: 2\n---\n# Meeting \(name)\n\n**Me** [00:00:01]\n\(text)\n"
        try body.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        return folder
    }

    /// A file transcript at `url` (any folder).
    @discardableResult
    static func transcript(at url: URL, at date: Date, title: String, text: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = "---\ntype: source\ntitle: \"\(title)\"\ntags: [transcript]\nstatus: stable\nstarted_at: \(iso(date))\nduration_seconds: 90\n---\n# \(title)\n\n\(text)\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
