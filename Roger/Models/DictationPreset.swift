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
        aiPrompt: "Add proper punctuation, capitalization, and paragraph breaks to this dictated text. Preserve the original wording exactly. Return only the corrected text, nothing else.",
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
        aiPrompt: "Add proper punctuation, capitalization, and paragraph breaks to this dictated text. Preserve the original wording exactly. Return only the corrected text, nothing else.",
        rewritePrompt: "Rewrite this dictated text as clear, professional prose suitable for emails and documents. Maintain the original meaning and tone. Return only the rewritten text, nothing else.",
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
        aiPrompt: "Add proper punctuation and capitalization to this dictated text. Preserve technical terms, function names, variable names, and code references exactly as spoken. Format inline code references with backticks. Return only the corrected text, nothing else.",
        rewritePrompt: "",
        dictionaryEntries: []
    )

    static let builtInPresets: [DictationPreset] = [plain, polished, professional, code]

    static let defaultPresetID = polishedID
}
