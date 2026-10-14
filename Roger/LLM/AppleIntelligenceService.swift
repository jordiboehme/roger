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
        AppleIntelligenceStatus.current.note ?? ""
    }
}
#endif

/// Whether Apple Intelligence can process text on this Mac, with a plain
/// reason when it cannot. Settings > Text Model shows it.
enum AppleIntelligenceStatus: Equatable {
    case available
    case unavailable(Reason)

    enum Reason: Equatable {
        case needsMacOS26
        case deviceNotEligible
        case notEnabled
        case modelNotReady
        case other
    }

    var isAvailable: Bool { self == .available }

    /// The reason as a sentence, nil when available.
    var note: String? {
        switch self {
        case .available: return nil
        case .unavailable(.needsMacOS26): return "Needs macOS 26 or later."
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.notEnabled): return "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading."
        case .unavailable(.other): return "Apple Intelligence is not available."
        }
    }

    /// Asks the system model now.
    static var current: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: return .unavailable(.notEnabled)
                case .modelNotReady: return .unavailable(.modelNotReady)
                @unknown default: return .unavailable(.other)
                }
            }
        }
        #endif
        return .unavailable(.needsMacOS26)
    }
}

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
