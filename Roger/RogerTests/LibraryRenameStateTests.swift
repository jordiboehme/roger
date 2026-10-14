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
}
