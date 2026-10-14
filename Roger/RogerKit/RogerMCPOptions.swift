import Foundation

public struct RogerMCPOptionsError: Error, Equatable {
    public let message: String
}

/// `roger-mcp [--library <folder>] [--verbose]`, `--version`, `--help`.
public struct RogerMCPOptions: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case serve
        case version
        case help
    }

    public var mode: Mode
    public var library: String?
    public var verbose: Bool

    public init(mode: Mode = .serve, library: String? = nil, verbose: Bool = false) {
        self.mode = mode
        self.library = library
        self.verbose = verbose
    }

    public static let usage = """
    Usage: roger-mcp [--library <folder>] [--verbose]
           roger-mcp --version
    Serves Roger's library to MCP clients over stdin and stdout.
    Without --library it uses the library folder set in Roger.
    """

    public static func parse(_ arguments: [String]) throws -> RogerMCPOptions {
        var options = RogerMCPOptions()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--library":
                guard let folder = rest.popFirst(), !folder.hasPrefix("--") else {
                    throw RogerMCPOptionsError(message: "--library needs a folder.")
                }
                options.library = folder
            case "--verbose":
                options.verbose = true
            case "--version":
                options.mode = .version
            case "--help", "-h":
                options.mode = .help
            default:
                throw RogerMCPOptionsError(message: "Unknown argument: \(argument)")
            }
        }
        return options
    }
}

public enum RogerVersion {
    /// `CFBundleShortVersionString` of the app whose `Contents/MacOS/` holds
    /// `executable` (symlinks resolved, so a Homebrew link works). Nil when
    /// the binary is not inside an app.
    public static func enclosingApp(executable: URL) -> String? {
        let resolved = executable.resolvingSymlinksInPath()
        let macOS = resolved.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}
