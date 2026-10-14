import Foundation

/// One rename in the detail header. It ends once: Return, the focus
/// leaving the field or a click elsewhere commit it, Esc cancels it. What
/// comes after the end (the focus loss that follows Return or Esc) does
/// nothing, so a title is never written twice and Esc never writes.
struct LibraryRenameState: Equatable, Sendable {
    private(set) var isActive = false
    /// What the text field shows.
    var draft = ""
    private var original = ""

    mutating func begin(title: String) {
        isActive = true
        draft = title
        original = title
    }

    /// The title to write, or nil: not renaming, ended already or unchanged.
    mutating func commit() -> String? {
        guard isActive else { return nil }
        isActive = false
        return draft == original ? nil : draft
    }

    mutating func cancel() {
        isActive = false
    }
}
