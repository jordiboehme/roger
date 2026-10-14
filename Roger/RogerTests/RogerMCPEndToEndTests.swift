import Foundation
import Testing
@testable import Roger

/// A running roger-mcp: newline-delimited JSON-RPC on stdin and stdout.
/// Lines on stdout that are not JSON-RPC 2.0 are kept in `badLines`.
final class MCPProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [[String: Any]] = []
    private var bad: [String] = []

    init(binary: URL, arguments: [String]) throws {
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        try process.run()
    }

    func send(_ json: String) {
        input.fileHandleForWriting.write(Data((json + "\n").utf8))
    }

    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    var badLines: [String] { lock.withLock { bad } }

    func response(id: Int) -> [String: Any]? {
        lock.withLock { messages.first { ($0["id"] as? Int) == id } }
    }

    /// Responses may arrive in any order; wait until all ids are there.
    func waitForResponses(ids: [Int], timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ids.allSatisfy({ response(id: $0) != nil }) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func waitForExit(timeout: TimeInterval) async throws -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }

    private func consume(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   object["jsonrpc"] as? String == "2.0" {
                    messages.append(object)
                } else {
                    bad.append(String(decoding: line, as: UTF8.self))
                }
            }
        }
    }
}

struct RogerMCPEndToEndTests {
    /// The helper embedded in the Roger.app that hosts these tests.
    private var binary: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/roger-mcp")
    }

    @Test func helperIsEmbeddedAndPrintsTheAppVersion() throws {
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let version = try #require(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        #expect(text == "roger-mcp \(version)\n")
        #expect(process.terminationStatus == 0)
    }

    @Test func servesInitializeToolsListAndGetChanges() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let entry = LogEntry(text: "Called the supplier", startedAt: date, endedAt: date.addingTimeInterval(5), presetName: "Log", language: nil)
        let md = try await LogEntryWriter.write(entry, layout: LibraryLayout(root: root), audioSamples: nil)
        try await ChangeLog(root: root).record(.written, ChangeKey.subject(markdownURL: md, kind: .log, root: root))

        let server = try MCPProcess(binary: binary, arguments: ["--library", root.path])
        server.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"roger-tests","version":"1"}}}"#)
        #expect(try await server.waitForResponses(ids: [1], timeout: 15))
        server.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        server.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        server.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_changes","arguments":{"consumer":"e2e"}}}"#)
        server.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_item","arguments":{"key":"../../etc/passwd"}}}"#)
        #expect(try await server.waitForResponses(ids: [2, 3, 4], timeout: 15))

        let initialize = try #require(server.response(id: 1)?["result"] as? [String: Any])
        let info = try #require(initialize["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "roger")
        #expect((initialize["instructions"] as? String)?.contains("get_changes") == true)

        let list = try #require(server.response(id: 2)?["result"] as? [String: Any])
        let tools = try #require(list["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String }.sorted() == RogerTools.names.sorted())
        for tool in tools {
            let annotations = tool["annotations"] as? [String: Any]
            let readOnly = annotations?["readOnlyHint"] as? Bool
            #expect(readOnly == (tool["name"] as? String != "ack"))
            if tool["name"] as? String == "ack" {
                let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
                #expect(properties?["library"] != nil)
            }
        }

        let call = try #require(server.response(id: 3)?["result"] as? [String: Any])
        #expect(call["isError"] as? Bool == false)
        let text = try #require((call["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.hasPrefix("from: 1\nupTo: 1\nmore: false\ncount: 1"))
        #expect(text.contains("Called the supplier"))
        #expect(text.contains("\nlibrary: \(LibraryPath.canonical(root))\n"))

        let rejected = try #require(server.response(id: 4)?["result"] as? [String: Any])
        #expect(rejected["isError"] as? Bool == true)

        server.closeInput()
        #expect(try await server.waitForExit(timeout: 10) == 0)
        #expect(server.badLines.isEmpty)
    }
}
