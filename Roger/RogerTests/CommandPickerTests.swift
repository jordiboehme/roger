import Foundation
import Testing
@testable import Roger

struct CommandPickerTests {
    @Test func optionsListNothingThenCommands() {
        let a = AgentCommand(name: "A", commandLine: "a", prompt: "", workingDirectory: "~")
        let opts = CommandPicker.options(selection: nil, commands: [a])
        #expect(opts.map(\.label) == ["Nothing", "A"])
        #expect(opts.map(\.id) == [nil, a.id])
    }

    @Test func missingSelectionIsShown() {
        let gone = UUID()
        let opts = CommandPicker.options(selection: gone, commands: [])
        #expect(opts.map(\.label) == ["Nothing", "Missing command"])
        #expect(opts.last?.id == gone)
    }
}
