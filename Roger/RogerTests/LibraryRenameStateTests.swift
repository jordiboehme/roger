import Testing
@testable import Roger

struct LibraryRenameStateTests {
    @Test func commitHappensOnce() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "New"
        #expect(rename.commit() == "New")   // Return
        #expect(rename.commit() == nil)     // the focus loss that follows
        #expect(!rename.isActive)
    }

    @Test func cancelThenFocusLossCommitsNothing() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "New"
        rename.cancel()                     // Esc
        #expect(rename.commit() == nil)     // the focus loss that follows
    }

    @Test func anUnchangedTitleIsNotWritten() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        #expect(rename.commit() == nil)
    }

    @Test func aNewRenameStartsFromTheCurrentTitle() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "Typed"
        rename.cancel()
        rename.begin(title: "Current")
        #expect(rename.draft == "Current")
        rename.draft = "Next"
        #expect(rename.commit() == "Next")
    }

    @Test func nothingHappensWithoutARename() {
        var rename = LibraryRenameState()
        #expect(rename.commit() == nil)
    }

    /// Spaces around the title are no change: nothing is written.
    @Test func aWhitespaceOnlyChangeIsNotWritten() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "  Old \n"
        #expect(rename.commit() == nil)
    }

    /// The title is written as it is saved: one line, trimmed.
    @Test func theCommittedTitleIsTrimmed() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "  New title "
        #expect(rename.commit() == "New title")
    }

    /// An empty title goes quietly back to the old one: no write, no error.
    @Test func anEmptyDraftIsNotWritten() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "   "
        #expect(rename.commit() == nil)
        #expect(!rename.isActive)
    }
}
