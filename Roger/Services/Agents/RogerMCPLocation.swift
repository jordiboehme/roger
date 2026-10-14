import Foundation

/// Which `roger-mcp` path Roger hands to agents: a Homebrew link when it
/// points into this very app, else the binary inside the running app.
/// Always absolute: agents started from the Dock may have a short `PATH`.
enum RogerMCPLocation {
    static let homebrewLinks = ["/opt/homebrew/bin/roger-mcp", "/usr/local/bin/roger-mcp"]

    enum Choice: Equatable {
        case usable(String)
        /// Why no path can be handed out (the app runs from a disk image or
        /// a translocated copy, which goes away).
        case unusable(String)
    }

    static func bundled(in appBundle: URL) -> URL {
        appBundle.appendingPathComponent("Contents/MacOS/roger-mcp")
    }

    static func choose(appBundle: URL, links: [String] = homebrewLinks) -> Choice {
        let path = appBundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return .unusable("Roger runs from a temporary place. Move Roger to the Applications folder, open it from there and try again.")
        }
        let binary = bundled(in: appBundle)
        let target = binary.resolvingSymlinksInPath().path
        for link in links where FileManager.default.fileExists(atPath: link) {
            if URL(fileURLWithPath: link).resolvingSymlinksInPath().path == target {
                return .usable(link)
            }
        }
        return .usable(binary.path)
    }
}
