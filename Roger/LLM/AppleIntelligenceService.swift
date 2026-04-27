import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *)
struct AppleIntelligenceService: LLMService {
    let providerType: LLMProviderType = .appleIntelligence

    var isAvailable: Bool {
        get async {
            SystemLanguageModel.default.isAvailable
        }
    }

    func processText(_ text: String, prompt: String) async throws -> String {
        guard SystemLanguageModel.default.isAvailable else {
            throw LLMError.providerUnavailable(unavailabilityReason)
        }

        let session = LanguageModelSession()
        let fullPrompt = "\(prompt)\n\nText to process:\n\(text)"
        do {
            let response = try await session.respond(to: fullPrompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let genErr as LanguageModelSession.GenerationError {
            if case .guardrailViolation = genErr {
                throw LLMError.guardrailViolation
            }
            throw genErr
        }
    }

    private var unavailabilityReason: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return ""
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Enable Apple Intelligence in System Settings > Apple Intelligence & Siri"
            case .modelNotReady:
                return "Apple Intelligence is still downloading"
            @unknown default:
                return "Apple Intelligence is not available"
            }
        }
    }
}
#endif

struct AppleIntelligenceFallbackService: LLMService {
    let providerType: LLMProviderType = .appleIntelligence

    var isAvailable: Bool {
        get async { false }
    }

    func processText(_ text: String, prompt: String) async throws -> String {
        throw LLMError.providerUnavailable("Apple Intelligence requires macOS 26 or later")
    }
}

/// Apple Intelligence's FoundationModels supports a small curated language set
/// that's narrower than Whisper's. Used by the preset editor to warn users
/// when they pin a Whisper language the local AI step won't be able to follow.
enum AppleIntelligenceLanguageSupport {
    /// Hardcoded fallback for builds running on macOS < 26 where the runtime
    /// list isn't available. The macOS-26 path below wins when present, so
    /// future expansions of FoundationModels' language set are picked up
    /// automatically.
    static let fallbackCodes: Set<String> = ["en", "fr", "de", "it", "pt", "es", "ja", "ko", "zh"]

    static func supports(languageCode code: String) -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let supported = SystemLanguageModel.default.supportedLanguages
            return supported.contains { $0.languageCode?.identifier == code }
        }
        #endif
        return fallbackCodes.contains(code)
    }
}
