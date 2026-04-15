import Foundation

enum LLMProviderType: String, Codable, CaseIterable, Identifiable {
    case appleIntelligence
    case ollama
    case claude
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .ollama: "Ollama"
        case .claude: "Claude"
        case .openai: "OpenAI"
        }
    }

    var icon: String {
        switch self {
        case .appleIntelligence: "apple.intelligence"
        case .ollama: "server.rack"
        case .claude: "message.badge.waveform"
        case .openai: "brain.head.profile"
        }
    }

    var isLocal: Bool {
        switch self {
        case .appleIntelligence, .ollama: true
        case .claude, .openai: false
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .appleIntelligence, .ollama: false
        case .claude, .openai: true
        }
    }
}
