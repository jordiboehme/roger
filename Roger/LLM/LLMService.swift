import Foundation

protocol LLMService: Sendable {
    var providerType: LLMProviderType { get }
    var isAvailable: Bool { get async }
    func processText(_ text: String, prompt: String) async throws -> String
}

enum LLMError: LocalizedError {
    case providerUnavailable(String)
    case apiKeyMissing(LLMProviderType)
    case requestFailed(String)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable(let reason): "LLM provider unavailable: \(reason)"
        case .apiKeyMissing(let provider): "No API key configured for \(provider.displayName)"
        case .requestFailed(let message): "LLM request failed: \(message)"
        case .invalidResponse: "Invalid response from LLM"
        case .networkError(let error): "Network error: \(error.localizedDescription)"
        }
    }
}
