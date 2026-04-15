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
        let response = try await session.respond(to: fullPrompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
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
