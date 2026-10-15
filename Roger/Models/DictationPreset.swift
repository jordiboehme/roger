import Foundation

enum PresetRotationDirection {
    case previous
    case next
}

enum TrailingCharacter: String, Codable, CaseIterable, Identifiable {
    case none
    case space
    case newline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Nothing"
        case .space: return "Space"
        case .newline: return "Newline"
        }
    }

    var character: String {
        switch self {
        case .none: return ""
        case .space: return " "
        case .newline: return "\n"
        }
    }
}

/// Where a preset's text goes after post-processing.
enum PresetOutput: String, Codable, CaseIterable, Identifiable {
    /// Typed at the cursor (Accessibility API, clipboard fallback).
    case insertAtCursor
    /// Saved as a Markdown log entry in the library; nothing is typed.
    case logEntry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .insertAtCursor: return "Insert at cursor"
        case .logEntry: return "Save as log entry"
        }
    }
}

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
    var trailingCharacter: TrailingCharacter
    var sendReturnAfterInsert: Bool
    var excludedFromRotation: Bool
    /// ISO-639-1 language code passed to WhisperKit, or nil for auto-detect.
    /// Ignored when the active model is English-only (see AppState.resolvedLanguage).
    var language: String?
    var output: PresetOutput
    /// Log presets only: also save the recording as `.m4a` next to the entry.
    var keepAudio: Bool
    /// Log presets only: also record what the Mac plays (calls, videos).
    /// The entry then reads like a meeting ("Me" and "Other N").
    var recordSystemAudio: Bool
    /// The configured command (`AgentCommand.id`) to run after a log entry
    /// is saved. Nil runs nothing. Only used when `output == .logEntry`.
    var commandID: UUID?

    var requiresAI: Bool {
        enableAIFormatting || enableRewrite
    }

    init(
        id: UUID,
        name: String,
        isBuiltIn: Bool,
        enableFillerRemoval: Bool,
        enableDedup: Bool,
        enableAIFormatting: Bool,
        enableCustomDictionary: Bool,
        enableRewrite: Bool,
        aiPrompt: String,
        rewritePrompt: String,
        dictionaryEntries: [DictionaryEntry],
        trailingCharacter: TrailingCharacter = .none,
        sendReturnAfterInsert: Bool = false,
        excludedFromRotation: Bool = false,
        language: String? = nil,
        output: PresetOutput = .insertAtCursor,
        keepAudio: Bool = false,
        recordSystemAudio: Bool = false,
        commandID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.enableFillerRemoval = enableFillerRemoval
        self.enableDedup = enableDedup
        self.enableAIFormatting = enableAIFormatting
        self.enableCustomDictionary = enableCustomDictionary
        self.enableRewrite = enableRewrite
        self.aiPrompt = aiPrompt
        self.rewritePrompt = rewritePrompt
        self.dictionaryEntries = dictionaryEntries
        self.trailingCharacter = trailingCharacter
        self.sendReturnAfterInsert = sendReturnAfterInsert
        self.excludedFromRotation = excludedFromRotation
        self.language = language
        self.output = output
        self.keepAudio = keepAudio
        self.recordSystemAudio = recordSystemAudio
        self.commandID = commandID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isBuiltIn = try c.decode(Bool.self, forKey: .isBuiltIn)
        enableFillerRemoval = try c.decode(Bool.self, forKey: .enableFillerRemoval)
        enableDedup = try c.decode(Bool.self, forKey: .enableDedup)
        enableAIFormatting = try c.decode(Bool.self, forKey: .enableAIFormatting)
        enableCustomDictionary = try c.decode(Bool.self, forKey: .enableCustomDictionary)
        enableRewrite = try c.decode(Bool.self, forKey: .enableRewrite)
        aiPrompt = try c.decode(String.self, forKey: .aiPrompt)
        rewritePrompt = try c.decode(String.self, forKey: .rewritePrompt)
        dictionaryEntries = try c.decode([DictionaryEntry].self, forKey: .dictionaryEntries)
        trailingCharacter = try c.decodeIfPresent(TrailingCharacter.self, forKey: .trailingCharacter) ?? .none
        sendReturnAfterInsert = try c.decodeIfPresent(Bool.self, forKey: .sendReturnAfterInsert) ?? false
        excludedFromRotation = try c.decodeIfPresent(Bool.self, forKey: .excludedFromRotation) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        output = try c.decodeIfPresent(PresetOutput.self, forKey: .output) ?? .insertAtCursor
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? false
        recordSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .recordSystemAudio) ?? false
        commandID = try c.decodeIfPresent(UUID.self, forKey: .commandID)
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
    private static let logID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!

    /// Copy with every AI step off. Used when the LLM is unavailable or
    /// refuses the text. Keeps every other field, including `output`, so a
    /// log preset never falls back to typing at the cursor.
    var withoutAI: DictationPreset {
        var copy = self
        copy.enableAIFormatting = false
        copy.enableRewrite = false
        return copy
    }

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
        rewritePrompt: "Add emojis to make this text fun and expressive, the way a person would text a friend. Place emojis at natural points — end of sentences, after key words, or to punctuate a thought. Aim for 3–6 emojis spread through the text, not one after every word. Keep the original words unchanged. Add punctuation and capitalization. Return only the rewritten text.",
        dictionaryEntries: []
    )

    static let log = DictationPreset(
        id: logID,
        name: "Log",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: false,
        enableCustomDictionary: false,
        enableRewrite: false,
        aiPrompt: "",
        rewritePrompt: "",
        dictionaryEntries: [],
        excludedFromRotation: true,
        output: .logEntry
    )

    static let builtInPresets: [DictationPreset] = [plain, polished, professional, code, caveman, yoda, emoji, log]

    static let defaultPresetID = polishedID

    /// The preset files and meetings use: the stored one when it has no AI
    /// steps, else the user's Plain (which may be renamed), else the
    /// original Plain. These transcripts never reach an AI provider.
    static func localPreset(id: UUID, in presets: [DictationPreset]) -> DictationPreset {
        if let preset = presets.first(where: { $0.id == id }), !preset.requiresAI {
            return preset
        }
        if let userPlain = presets.first(where: { $0.id == plainID }), !userPlain.requiresAI {
            return userPlain
        }
        return plain
    }
}
