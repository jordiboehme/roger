import Foundation
import Observation
import WhisperKit

@Observable
final class AppState {
    enum DictationState: Equatable {
        case idle
        case listening
        case transcribing
        case processing
        case inserting
        case error(String)
    }

    // MARK: - Dictation State

    var dictationState: DictationState = .idle
    var lastTranscription: String?

    // MARK: - General Settings

    var transcriptionMode: TranscriptionMode {
        didSet { defaults.set(transcriptionMode.rawValue, forKey: "transcriptionMode") }
    }
    var activationMode: ActivationMode {
        didSet { defaults.set(activationMode.rawValue, forKey: "activationMode") }
    }
    var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") }
    }
    var minimumRecordingDuration: TimeInterval {
        didSet { defaults.set(minimumRecordingDuration, forKey: "minimumRecordingDuration") }
    }

    // MARK: - LLM Settings

    var selectedLLMProvider: LLMProviderType {
        didSet { defaults.set(selectedLLMProvider.rawValue, forKey: "selectedLLMProvider") }
    }
    var ollamaBaseURL: String {
        didSet { defaults.set(ollamaBaseURL, forKey: "ollamaBaseURL") }
    }
    var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollamaModel") }
    }
    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: "claudeModel") }
    }
    var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: "openAIModel") }
    }

    // MARK: - Preset Settings

    var activePresetID: UUID {
        didSet { defaults.set(activePresetID.uuidString, forKey: "activePresetID") }
    }
    var presets: [DictationPreset] {
        didSet { savePresets() }
    }

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    var activePreset: DictationPreset {
        presets.first { $0.id == activePresetID } ?? .polished
    }

    // MARK: - Computed

    var isListening: Bool {
        dictationState == .listening
    }

    var isBusy: Bool {
        switch dictationState {
        case .transcribing, .processing, .inserting:
            return true
        default:
            return false
        }
    }

    var menuBarIcon: String {
        switch dictationState {
        case .idle:
            return "waveform"
        case .listening:
            return "waveform.circle.fill"
        case .transcribing, .processing:
            return "ellipsis.circle"
        case .inserting:
            return "text.cursor"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch dictationState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .processing:
            return "Processing…"
        case .inserting:
            return "Inserting…"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    // MARK: - LLM Factory

    func currentLLMService() -> any LLMService {
        switch selectedLLMProvider {
        case .ollama:
            OllamaService(baseURL: ollamaBaseURL, model: ollamaModel)
        case .claude:
            ClaudeService(model: claudeModel)
        case .openai:
            OpenAIService(model: openAIModel)
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                AppleIntelligenceService()
            } else {
                AppleIntelligenceFallbackService()
            }
            #else
            AppleIntelligenceFallbackService()
            #endif
        }
    }

    // MARK: - Init

    private let defaults = UserDefaults.standard

    init() {
        self.transcriptionMode = TranscriptionMode(rawValue: defaults.string(forKey: "transcriptionMode") ?? "") ?? .multilingual
        self.activationMode = ActivationMode(rawValue: defaults.string(forKey: "activationMode") ?? "") ?? .pushToTalk
        self.restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        self.minimumRecordingDuration = defaults.object(forKey: "minimumRecordingDuration") as? TimeInterval ?? 1.5

        self.selectedLLMProvider = LLMProviderType(rawValue: defaults.string(forKey: "selectedLLMProvider") ?? "") ?? .appleIntelligence
        self.ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self.ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
        self.claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-sonnet-4-20250514"
        self.openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o"

        self.activePresetID = UUID(uuidString: defaults.string(forKey: "activePresetID") ?? "") ?? DictationPreset.defaultPresetID
        self.presets = Self.loadPresets() ?? DictationPreset.builtInPresets
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    // MARK: - Persistence

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: "presets")
    }

    private static func loadPresets() -> [DictationPreset]? {
        guard let data = UserDefaults.standard.data(forKey: "presets"),
              let presets = try? JSONDecoder().decode([DictationPreset].self, from: data)
        else { return nil }
        return presets
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable, Codable {
    case englishOnly
    case multilingual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .englishOnly: return "English Only (faster)"
        case .multilingual: return "Multilingual"
        }
    }

    var modelName: String {
        let models = WhisperKit.recommendedModels()
        switch self {
        case .englishOnly:
            // Prefer distil models (fast, English-only), then .en models
            let distil = models.supported.filter { $0.contains("distil") }
            if let best = distil.last { return best }
            let en = models.supported.filter { $0.contains(".en") }
            if let best = en.last { return best }
            return models.default
        case .multilingual:
            return models.default
        }
    }

    /// Short model name for display in UI
    var modelDescription: String {
        let name = modelName
        // Strip common prefixes for readability
        return name
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_distil-", with: "distil-")
    }

    /// Language code passed to WhisperKit. Nil = auto-detect.
    var whisperLanguage: String? {
        switch self {
        case .englishOnly: return "en"
        case .multilingual: return nil // auto-detect
        }
    }

    /// Human-readable language name for AI prompts
    var languageHint: String? {
        switch self {
        case .englishOnly: return "English"
        case .multilingual: return nil // detected at runtime
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to Talk (hold to record)"
        case .toggle: return "Toggle (press to start/stop)"
        }
    }
}
