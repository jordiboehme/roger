import Testing
@testable import RogerKit

struct CommandTemplateTests {
    private let item = CommandItemInfo(
        file: "/Users/a/Documents/Roger/Logs/2026/10/2026-10-15 09-00-00.md",
        key: "log/2026/10/2026-10-15 09-00-00",
        title: "Log 2026-10-15 09:00 - Call Anna about the offer",
        kind: "log"
    )

    @Test func quotesSingleQuotes() {
        #expect(CommandTemplate.shellQuote("it's") == "'it'\\''s'")
    }

    @Test func quotesShellMetacharactersLiterally() {
        let nasty = "a $HOME `id` ; rm -rf / \"x\"\nnext"
        #expect(CommandTemplate.shellQuote(nasty) == "'" + nasty + "'")
    }

    @Test func emptyValueBecomesEmptyQuotes() {
        #expect(CommandTemplate.shellQuote("") == "''")
    }

    @Test func promptPlaceholdersArePlainText() {
        let out = CommandTemplate.renderPrompt("Ingest {kind} {key} at {file}: {title}", item: item)
        #expect(out == "Ingest log log/2026/10/2026-10-15 09-00-00 at \(item.file): \(item.title)")
    }

    @Test func unknownPlaceholdersStay() {
        #expect(CommandTemplate.renderPrompt("{nope} {key}", item: item) == "{nope} \(item.key)")
        #expect(CommandTemplate.renderCommandLine("echo {nope}", prompt: "p", item: item) == "echo {nope}")
    }

    @Test func commandLineGetsQuotedPrompt() {
        let line = CommandTemplate.renderCommandLine("claude -p {prompt}", prompt: "Use /ingest-roger, it's new", item: item)
        #expect(line == "claude -p 'Use /ingest-roger, it'\\''s new'")
    }

    @Test func commandLineQuotesItemPlaceholders() {
        let line = CommandTemplate.renderCommandLine("open {file}", prompt: "", item: item)
        #expect(line == "open '\(item.file)'")
    }

    @Test func placeholderTextInsideValuesIsNotExpandedAgain() {
        let tricky = CommandItemInfo(file: "/tmp/{key}.md", key: "K", title: "{prompt}", kind: "log")
        #expect(CommandTemplate.renderPrompt("{title} {file}", item: tricky) == "{prompt} /tmp/{key}.md")
        #expect(CommandTemplate.renderCommandLine("x {file}", prompt: "P", item: tricky) == "x '/tmp/{key}.md'")
    }
}
