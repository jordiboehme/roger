import Foundation
import FluidAudio

/// Catalog of languages Parakeet TDT v3 can transcribe, sourced from
/// FluidAudio's `Language` enum so the picker stays in sync with the model
/// rather than a hand-maintained copy. Display names come from `Locale` so they
/// localize and need no manual upkeep.
///
/// (Name kept for continuity with existing call sites; the underlying model is
/// Parakeet, not Whisper.)
enum WhisperLanguage {
    struct Entry: Hashable {
        let code: String
        let displayName: String
    }

    /// All languages Parakeet v3 supports, sorted by display name.
    static let all: [Entry] = Language.allCases
        .map { Entry(code: $0.rawValue, displayName: name(for: $0.rawValue)) }
        .sorted { $0.displayName < $1.displayName }

    /// Resolves a stored code back to a display name, with a graceful fallback
    /// so a preset referencing a dropped language still renders.
    static func displayName(for code: String) -> String {
        all.first(where: { $0.code == code })?.displayName ?? code.uppercased()
    }

    private static func name(for code: String) -> String {
        (Locale.current.localizedString(forLanguageCode: code) ?? code).capitalized
    }
}
