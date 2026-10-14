import Foundation

/// The two Roger settings `roger-mcp` reads.
public struct RogerPreferences: Equatable, Sendable {
    public var libraryRoot: String?
    public var extraScanFolders: [String]

    public init(libraryRoot: String?, extraScanFolders: [String]) {
        self.libraryRoot = libraryRoot
        self.extraScanFolders = extraScanFolders
    }
}

public enum LibraryAccess: Equatable, Sendable {
    case ready
    /// The folder or `.roger/changes.jsonl` is missing.
    case notSetUp
    /// macOS refused (TCC Files and Folders, or plain permissions).
    case notReadable
}

public struct LibraryLocation: Equatable, Sendable {
    public let root: URL
    public let extraFolders: [URL]
    /// False with `--library`: then Roger's extra folders and external
    /// transcripts belong to another library and are left out.
    public let usesRogerSettings: Bool
    public let access: LibraryAccess
}

/// Finds the library on every call: `--library`, then Roger's
/// `libraryRoot` setting, then `~/Documents/Roger/`. Reading the setting
/// each time means a folder change in Roger reaches a running server.
public struct LibraryLocator: Sendable {
    public static let bundleID = "com.jordiboehme.roger"

    private let argument: String?
    private let preferences: @Sendable () -> RogerPreferences
    private let defaultRoot: URL

    public init(
        argument: String?,
        preferences: @escaping @Sendable () -> RogerPreferences = LibraryLocator.readPreferences,
        defaultRoot: URL = LibraryLayout.defaultRoot
    ) {
        self.argument = argument
        self.preferences = preferences
        self.defaultRoot = defaultRoot
    }

    public func locate() -> LibraryLocation {
        if let argument, !argument.isEmpty {
            let root = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath, isDirectory: true)
            return LibraryLocation(root: root, extraFolders: [], usesRogerSettings: false, access: Self.probe(root: root))
        }
        let settings = preferences()
        let root = settings.libraryRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultRoot
        return LibraryLocation(
            root: root,
            extraFolders: settings.extraScanFolders.map { URL(fileURLWithPath: $0, isDirectory: true) },
            usesRogerSettings: true,
            access: Self.probe(root: root)
        )
    }

    /// Roger's settings, fresh from disk.
    public static func readPreferences() -> RogerPreferences {
        let app = bundleID as CFString
        CFPreferencesAppSynchronize(app)
        let root = CFPreferencesCopyAppValue("libraryRoot" as CFString, app) as? String
        let extras = CFPreferencesCopyAppValue("extraScanFolders" as CFString, app) as? [String] ?? []
        return RogerPreferences(libraryRoot: root, extraScanFolders: extras)
    }

    /// Opens `changes.jsonl` for reading: `ENOENT` (or anything else that
    /// is not a permission error) means not set up; `EPERM` and `EACCES`
    /// mean macOS or the file system refused.
    public static func probe(root: URL) -> LibraryAccess {
        let fd = open(ChangeLogFile.url(root: root).path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return .ready
        }
        return (errno == EPERM || errno == EACCES) ? .notReadable : .notSetUp
    }

    /// The text for a library that is not ready; nil when it is.
    public static func accessMessage(_ access: LibraryAccess, root: URL) -> String? {
        switch access {
        case .ready:
            return nil
        case .notSetUp:
            return "No Roger library at \(root.path) yet. Start Roger once to set up the library."
        case .notReadable:
            return "Roger cannot read the library at \(root.path). macOS blocks this folder for the app that started roger-mcp. Allow it in System Settings > Privacy & Security > Files and Folders (for example for Terminal or Claude), then try again."
        }
    }
}
