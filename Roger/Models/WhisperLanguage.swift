import Foundation
import WhisperKit

/// Catalog of languages WhisperKit's multilingual checkpoints can decode.
/// Sourced from `WhisperKit.Constants.languages` so the picker stays in sync
/// with the underlying model rather than drifting against a hand-maintained
/// copy.
enum WhisperLanguage {
    struct Entry: Hashable {
        let code: String
        let displayName: String
    }

    /// Whisper's `Constants.languages` lists several names per code (e.g.
    /// "moldavian"/"moldovan" both map to "ro", "valencian"/"catalan" both to
    /// "ca"). Pick a single canonical English name per code so the picker has
    /// no duplicate codes and the chosen name is the one users expect.
    private static let canonicalNames: [String: String] = [
        "es": "spanish",
        "zh": "chinese",
        "ro": "romanian",
        "nl": "dutch",
        "ca": "catalan",
        "my": "burmese",
        "lb": "luxembourgish",
        "ps": "pashto",
        "ht": "haitian creole",
        "pa": "punjabi",
        "si": "sinhala",
    ]

    /// All multilingual languages Whisper supports, sorted by displayName.
    static let all: [Entry] = {
        var byCode: [String: String] = [:]
        for (name, code) in Constants.languages {
            if let canonical = canonicalNames[code] {
                byCode[code] = canonical
            } else if let existing = byCode[code] {
                // Deterministic tie-break: shorter name wins, then alphabetic.
                if name.count < existing.count || (name.count == existing.count && name < existing) {
                    byCode[code] = name
                }
            } else {
                byCode[code] = name
            }
        }
        return byCode
            .map { code, name in Entry(code: code, displayName: name.capitalized) }
            .sorted { $0.displayName < $1.displayName }
    }()

    /// Resolves a stored code back to a display name, with a graceful fallback
    /// so a preset referencing a language WhisperKit later drops still renders.
    static func displayName(for code: String) -> String {
        all.first(where: { $0.code == code })?.displayName ?? code.uppercased()
    }
}
