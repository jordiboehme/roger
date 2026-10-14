import Foundation

extension DictationPreset {
    /// The shipped version of a built-in preset, nil for a custom preset.
    var original: DictationPreset? {
        DictationPreset.builtInPresets.first { $0.id == id }
    }

    /// A built-in preset brought back to its shipped version. Keeps the id
    /// and whether it is hidden from the Caps Lock rotation (that is set in
    /// the preset list, not in the preset). A custom preset stays as it is.
    func resetToOriginal() -> DictationPreset {
        guard var copy = original else { return self }
        copy.excludedFromRotation = excludedFromRotation
        return copy
    }

    /// True for a built-in preset that differs from its shipped version.
    var isChangedBuiltIn: Bool {
        original != nil && resetToOriginal() != self
    }

    /// A custom copy with a new id, named "<name> Copy".
    func duplicated(id: UUID = UUID()) -> DictationPreset {
        var copy = self
        copy.id = id
        copy.name = "\(name) Copy"
        copy.isBuiltIn = false
        return copy
    }

    /// The preset "+ New Preset" adds.
    static func newCustom(id: UUID = UUID()) -> DictationPreset {
        DictationPreset(
            id: id,
            name: "Custom",
            isBuiltIn: false,
            enableFillerRemoval: true,
            enableDedup: true,
            enableAIFormatting: true,
            enableCustomDictionary: false,
            enableRewrite: false,
            aiPrompt: "Add proper punctuation and capitalization to this dictated text. Return only the corrected text, nothing else.",
            rewritePrompt: "",
            dictionaryEntries: []
        )
    }

    /// "No words", "1 word", "3 words".
    var dictionarySummary: String {
        switch dictionaryEntries.count {
        case 0: return "No words"
        case 1: return "1 word"
        case let count: return "\(count) words"
        }
    }
}
