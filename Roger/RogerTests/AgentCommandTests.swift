import Foundation
import Testing
@testable import Roger

struct AgentCommandTests {
    @Test func newCommandIsBlank() {
        let c = AgentCommand.blank()
        #expect(c.name == "New command")
        #expect(c.commandLine.isEmpty)
        #expect(c.prompt.isEmpty)
        #expect(c.workingDirectory == "~")
        #expect(c.mode == .headless)
        #expect(c.timeoutMinutes == 10)
        #expect(c.terminal == .terminal)
    }

    @Test func partialJSONDecodesWithDefaults() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"X","commandLine":"echo","prompt":"","workingDirectory":"~"}"#
        let c = try JSONDecoder().decode(AgentCommand.self, from: Data(json.utf8))
        #expect(c.mode == .headless)
        #expect(c.terminal == .terminal)
        #expect(c.timeoutMinutes == 10)
    }

    @Test func roundTrip() throws {
        var c = AgentCommand.blank()
        c.mode = .interactive
        c.terminal = .warp
        c.timeoutMinutes = 3
        let back = try JSONDecoder().decode(AgentCommand.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func expandsTilde() {
        let home = URL(fileURLWithPath: "/Users/someone")
        var c = AgentCommand.blank()
        #expect(c.expandedWorkingDirectory(home: home).path == "/Users/someone")
        c.workingDirectory = "~/git/roger"
        #expect(c.expandedWorkingDirectory(home: home).path == "/Users/someone/git/roger")
        c.workingDirectory = "/tmp"
        #expect(c.expandedWorkingDirectory(home: home).path == "/tmp")
    }
}
