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

extension CommandPickerTests {
    @Test func anUnnamedCommandShowsAsUntitled() {
        let a = AgentCommand(name: "", commandLine: "a", prompt: "", workingDirectory: "~")
        #expect(CommandPicker.options(selection: nil, commands: [a]).map(\.label) == ["Nothing", "Untitled"])
    }
}

@MainActor
struct CommandsPaneTests {
    @Test func displayPathUsesTheTildeForTheHomeFolder() {
        let home = "/Users/jordi"
        #expect(CommandsPane.displayPath("/Users/jordi", home: home) == "~")
        #expect(CommandsPane.displayPath("/Users/jordi/git/roger", home: home) == "~/git/roger")
        #expect(CommandsPane.displayPath("/Users/jordi2/git", home: home) == "/Users/jordi2/git")
        #expect(CommandsPane.displayPath("/tmp/work", home: home) == "/tmp/work")
    }

    @Test func searchedAgentsComeFromTheCatalog() {
        #expect(CommandsPane.searchedAgentsNote == "Roger looks for Claude Code, Codex, Gemini CLI, Copilot CLI and Kiro on your search path.")
    }

    @Test func notesFollowTheStyleRules() {
        for text in [CommandsPane.placeholderNote, CommandsPane.askNote, CommandsPane.trustNote, CommandsPane.searchedAgentsNote] {
            #expect(!text.contains("\u{2014}"))
            #expect(!text.contains("\u{2013}"))
            #expect(!text.contains(", and "))
        }
        #expect(CommandsPane.placeholderNote.hasSuffix("In the command line, values are quoted for the shell."))
    }
}
