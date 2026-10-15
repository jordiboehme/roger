import Foundation
import Testing
@testable import Roger

struct AgentCommandTests {
    @Test func exampleIsHeadlessClaude() {
        let c = AgentCommand.newClaudeExample()
        #expect(c.mode == .headless)
        #expect(c.commandLine == "claude -p {prompt}")
        #expect(c.workingDirectory == "~")
        #expect(c.prompt == AgentCommand.headlessExamplePrompt)
        #expect(c.timeoutMinutes == 10)
        #expect(c.terminal == .terminal)
    }

    @Test func untouchedExampleFollowsMode() {
        var c = AgentCommand.newClaudeExample()
        c.setMode(.interactive)
        #expect(c.commandLine == "claude {prompt}")
        #expect(c.prompt == AgentCommand.interactiveExamplePrompt)
        c.setMode(.headless)
        #expect(c.commandLine == "claude -p {prompt}")
        #expect(c.prompt == AgentCommand.headlessExamplePrompt)
    }

    @Test func editedCommandKeepsItsTextOnModeChange() {
        var c = AgentCommand.newClaudeExample()
        c.commandLine = "my-tool {prompt}"
        c.setMode(.interactive)
        #expect(c.mode == .interactive)
        #expect(c.commandLine == "my-tool {prompt}")
        #expect(c.prompt == AgentCommand.headlessExamplePrompt)
    }

    @Test func partialJSONDecodesWithDefaults() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"X","commandLine":"echo","prompt":"","workingDirectory":"~"}"#
        let c = try JSONDecoder().decode(AgentCommand.self, from: Data(json.utf8))
        #expect(c.mode == .headless)
        #expect(c.terminal == .terminal)
        #expect(c.timeoutMinutes == 10)
    }

    @Test func roundTrip() throws {
        var c = AgentCommand.newClaudeExample()
        c.mode = .interactive
        c.terminal = .warp
        c.timeoutMinutes = 3
        let back = try JSONDecoder().decode(AgentCommand.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func expandsTilde() {
        let home = URL(fileURLWithPath: "/Users/someone")
        var c = AgentCommand.newClaudeExample()
        #expect(c.expandedWorkingDirectory(home: home).path == "/Users/someone")
        c.workingDirectory = "~/git/roger"
        #expect(c.expandedWorkingDirectory(home: home).path == "/Users/someone/git/roger")
        c.workingDirectory = "/tmp"
        #expect(c.expandedWorkingDirectory(home: home).path == "/tmp")
    }
}
