// RogerKit holds the library code shared with roger-mcp. Re-exported so
// every app file (and `@testable import Roger` in RogerTests) sees it
// without its own import.
@_exported import RogerKit

// DeveloperToolsSupport (pulled in by SwiftUI and AppKit) also declares a
// `LibraryItem`. A local alias keeps the app's name unambiguous.
typealias LibraryItem = RogerKit.LibraryItem
