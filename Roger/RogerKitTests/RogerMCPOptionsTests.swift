import Foundation
import Testing
@testable import RogerKit

struct RogerMCPOptionsTests {
    @Test func defaultsToServing() throws {
        #expect(try RogerMCPOptions.parse([]) == RogerMCPOptions(mode: .serve, library: nil, verbose: false))
    }

    @Test func readsLibraryAndVerbose() throws {
        let options = try RogerMCPOptions.parse(["--library", "/tmp/Lib", "--verbose"])
        #expect(options == RogerMCPOptions(mode: .serve, library: "/tmp/Lib", verbose: true))
    }

    @Test func versionAndHelp() throws {
        #expect(try RogerMCPOptions.parse(["--version"]).mode == .version)
        #expect(try RogerMCPOptions.parse(["-h"]).mode == .help)
        #expect(try RogerMCPOptions.parse(["--help"]).mode == .help)
    }

    @Test func rejectsUnknownAndIncompleteArguments() {
        #expect(throws: RogerMCPOptionsError(message: "--library needs a folder.")) { try RogerMCPOptions.parse(["--library"]) }
        #expect(throws: RogerMCPOptionsError(message: "Unknown argument: --bogus")) { try RogerMCPOptions.parse(["--bogus"]) }
    }

    @Test func versionComesFromTheEnclosingApp() throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let contents = root.appendingPathComponent("Roger.app/Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "0.25.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let binary = macOS.appendingPathComponent("roger-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        #expect(RogerVersion.enclosingApp(executable: binary) == "0.25.0")

        // Homebrew links the binary into /opt/homebrew/bin.
        let link = root.appendingPathComponent("bin/roger-mcp")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        #expect(RogerVersion.enclosingApp(executable: link) == "0.25.0")

        #expect(RogerVersion.enclosingApp(executable: root.appendingPathComponent("loose/roger-mcp")) == nil)
    }
}
