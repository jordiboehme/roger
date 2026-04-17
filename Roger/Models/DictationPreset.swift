import Foundation

struct DictationPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var isBuiltIn: Bool
    var enableFillerRemoval: Bool
    var enableDedup: Bool
    var enableAIFormatting: Bool
    var enableCustomDictionary: Bool
    var enableRewrite: Bool
    var aiPrompt: String
    var rewritePrompt: String
    var dictionaryEntries: [DictionaryEntry]

    var requiresAI: Bool {
        enableAIFormatting || enableRewrite
    }
}

struct DictionaryEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var find: String
    var replace: String

    init(id: UUID = UUID(), find: String, replace: String) {
        self.id = id
        self.find = find
        self.replace = replace
    }
}

extension DictationPreset {
    // Deterministic UUIDs so activePresetID references survive across launches
    private static let plainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let polishedID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let professionalID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let codeID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private static let cavemanID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    private static let yodaID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    private static let emojiID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!

    static let plain = DictationPreset(
        id: plainID,
        name: "Plain",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: false,
        enableCustomDictionary: false,
        enableRewrite: false,
        aiPrompt: "",
        rewritePrompt: "",
        dictionaryEntries: []
    )

    static let polished = DictationPreset(
        id: polishedID,
        name: "Polished",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: true,
        enableCustomDictionary: true,
        enableRewrite: false,
        aiPrompt: "Add proper punctuation, capitalization and paragraph breaks to this dictated text. Preserve the original wording exactly. Return only the corrected text, nothing else.",
        rewritePrompt: "",
        dictionaryEntries: []
    )

    static let professional = DictationPreset(
        id: professionalID,
        name: "Professional",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: true,
        enableCustomDictionary: true,
        enableRewrite: true,
        aiPrompt: "Add proper punctuation, capitalization and paragraph breaks to this dictated text. Preserve the original wording exactly. Return only the corrected text, nothing else.",
        rewritePrompt: "Clean up this dictated text: fix grammar, improve sentence structure and make it read naturally. Keep the original meaning and words as much as possible — do not change the format, do not add greetings, sign-offs, subject lines or any text that wasn't in the original. Return only the cleaned-up text, nothing else.",
        dictionaryEntries: []
    )

    static let code = DictationPreset(
        id: codeID,
        name: "Code",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: true,
        enableCustomDictionary: true,
        enableRewrite: false,
        aiPrompt: "Add proper punctuation and capitalization to this dictated text. Preserve technical terms, function names, variable names and code references exactly as spoken. Format inline code references with backticks. Return only the corrected text, nothing else.",
        rewritePrompt: "",
        dictionaryEntries: []
    )

    static let caveman = DictationPreset(
        id: cavemanID,
        name: "Caveman",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: false,
        enableCustomDictionary: false,
        enableRewrite: true,
        aiPrompt: "",
        rewritePrompt: "Rewrite as terse caveman: drop articles (a/an/the), filler, pleasantries, hedging. Fragments OK. Short synonyms. Technical terms exact. Add punctuation. Return only the text.",
        dictionaryEntries: []
    )

    static let yoda = DictationPreset(
        id: yodaID,
        name: "Yoda",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: false,
        enableCustomDictionary: false,
        enableRewrite: true,
        aiPrompt: "",
        rewritePrompt: "Rewrite in Yoda's speech pattern from Star Wars: reorder to object-subject-verb where natural (\"Strong with the Force, you are\"). Keep original meaning and vocabulary. Short, wise, slightly archaic. Add punctuation. Return only the text.",
        dictionaryEntries: []
    )

    static let emoji = DictationPreset(
        id: emojiID,
        name: "Emoji",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: false,
        enableCustomDictionary: false,
        enableRewrite: true,
        aiPrompt: "",
        rewritePrompt: "Rewrite the text with aggressive emoji use: pack in emojis after every noun, verb, adjective and emotion. More is more — go heavy, be playful, stack multiple emojis where fitting. Do not change the original words. Add punctuation and capitalization. Return only the text.",
        dictionaryEntries: []
    )

    static let builtInPresets: [DictationPreset] = [plain, polished, professional, code, caveman, yoda, emoji]

    static let defaultPresetID = polishedID
}
