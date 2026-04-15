import Foundation

enum PostProcessingError: LocalizedError {
    case noAIProviderAvailable
    case aiProcessingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAIProviderAvailable:
            "No AI provider configured. Select one in Settings > AI Provider."
        case .aiProcessingFailed(let message):
            "AI processing failed: \(message)"
        }
    }
}
