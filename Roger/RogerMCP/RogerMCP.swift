import Foundation
import MCP
import os
import RogerKit

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "roger-mcp")

/// Notes go to the unified log, and to stderr with `--verbose`. Never to
/// stdout: stdout carries MCP only.
struct Diagnostics: Sendable {
    let verbose: Bool

    func note(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if verbose {
            FileHandle.standardError.write(Data(("roger-mcp: " + message + "\n").utf8))
        }
    }
}

/// Counts running tool calls, so the process does not exit in the middle
/// of one when stdin closes.
actor InFlight {
    private var count = 0

    func begin() { count += 1 }
    func end() { count -= 1 }

    func waitUntilIdle(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while count > 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@main
struct RogerMCP {
    static func main() async {
        // A client that goes away must not kill us with SIGPIPE mid-write.
        signal(SIGPIPE, SIG_IGN)

        let options: RogerMCPOptions
        do {
            options = try RogerMCPOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? RogerMCPOptionsError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data((message + "\n\n" + RogerMCPOptions.usage + "\n").utf8))
            exit(64)
        }

        let version = Bundle.main.executableURL.flatMap(RogerVersion.enclosingApp(executable:)) ?? "dev"
        switch options.mode {
        case .version:
            FileHandle.standardOutput.write(Data("roger-mcp \(version)\n".utf8))
            exit(0)
        case .help:
            FileHandle.standardOutput.write(Data((RogerMCPOptions.usage + "\n").utf8))
            exit(0)
        case .serve:
            break
        }

        let diagnostics = Diagnostics(verbose: options.verbose)
        let tools = RogerTools(locator: LibraryLocator(argument: options.library), registry: .standard)
        let inFlight = InFlight()
        let server = Server(
            name: "roger",
            version: version,
            instructions: ToolCatalog.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await inFlight.begin()
            let name = params.name
            let arguments = ValueBridge.arguments(params.arguments)
            // File work runs off the server actor.
            let output = await Task.detached { tools.call(name, arguments: arguments) }.value
            await inFlight.end()
            diagnostics.note("\(name): \(output.isError ? "error" : "ok")")
            return .init(content: [.text(text: output.text, annotations: nil, _meta: nil)], isError: output.isError)
        }

        do {
            try await server.start(transport: StdioTransport())
            diagnostics.note("serving \(version)")
        } catch {
            diagnostics.note("could not start: \(error.localizedDescription)")
            exit(1)
        }
        // Returns when stdin closes.
        await server.waitUntilCompleted()
        await inFlight.waitUntilIdle(timeout: .seconds(2))
        // Let the last response leave the transport.
        try? await Task.sleep(for: .milliseconds(200))
        diagnostics.note("stdin closed, exiting")
        exit(0)
    }
}
