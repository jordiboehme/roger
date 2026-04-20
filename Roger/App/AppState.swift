import Foundation
import Observation
import ServiceManagement
import WhisperKit
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LaunchAtLogin")

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
    var maximumRecordingDuration: TimeInterval {
        didSet {
            let clamped = min(600, max(30, maximumRecordingDuration))
            if clamped != maximumRecordingDuration {
                maximumRecordingDuration = clamped
                return
            }
            defaults.set(maximumRecordingDuration, forKey: "maximumRecordingDuration")
        }
    }
    var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    private var isSyncingLaunchAtLogin = false

    /// UID of the preferred input device, or nil for system default (automatic).
    var selectedInputDeviceUID: String? {
        didSet {
            if let uid = selectedInputDeviceUID {
                defaults.set(uid, forKey: "selectedInputDeviceUID")
            } else {
                defaults.removeObject(forKey: "selectedInputDeviceUID")
            }
        }
    }

    // MARK: - File Transcription Settings

    var fileTranscriptOutputLocation: FileTranscriptOutputLocation {
        didSet { defaults.set(fileTranscriptOutputLocation.rawValue, forKey: "fileTranscriptOutputLocation") }
    }
    /// Destination folder when `fileTranscriptOutputLocation == .customFolder`.
    /// Stored as a file URL; nil means the user hasn't picked one yet.
    var fileTranscriptOutputFolder: URL? {
        didSet {
            if let url = fileTranscriptOutputFolder {
                defaults.set(url.path, forKey: "fileTranscriptOutputFolder")
            } else {
                defaults.removeObject(forKey: "fileTranscriptOutputFolder")
            }
        }
    }
    /// Preset used to post-process dropped-file transcripts. Constrained to
    /// presets that don't require an LLM — file transcription should never
    /// silently reach out to an AI provider.
    var fileTranscriptionPresetID: UUID {
        didSet { defaults.set(fileTranscriptionPresetID.uuidString, forKey: "fileTranscriptionPresetID") }
    }

    /// Resolves `fileTranscriptionPresetID` to a live preset, guaranteeing no
    /// AI steps are enabled. Falls back to Plain if the configured preset was
    /// deleted or accidentally flipped to require AI.
    var fileTranscriptionPreset: DictationPreset {
        if let preset = presets.first(where: { $0.id == fileTranscriptionPresetID }), !preset.requiresAI {
            return preset
        }
        return DictationPreset.plain
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
        didSet {
            savePresets()
            pruneOrphanBindings()
        }
    }
    var modifierBindings: [CapsModifier: UUID] {
        didSet { saveModifierBindings() }
    }

    /// Removes a preset by id and cleans up any modifier binding pointing at it.
    /// Falls back activePresetID to the default if the removed preset was active.
    func removePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id {
            activePresetID = DictationPreset.defaultPresetID
        }
    }

    /// Assigns `presetID` to `modifier`, removing any previous binding for that modifier
    /// and any previous modifier that pointed to this preset.
    func bindModifier(_ modifier: CapsModifier, to presetID: UUID) {
        var next = modifierBindings
        for (mod, id) in next where id == presetID {
            next.removeValue(forKey: mod)
        }
        next[modifier] = presetID
        modifierBindings = next
    }

    /// Clears any modifier binding that points at `presetID`.
    func clearBinding(for presetID: UUID) {
        modifierBindings = modifierBindings.filter { $0.value != presetID }
    }

    /// Returns the modifier currently bound to `presetID`, if any.
    func modifier(for presetID: UUID) -> CapsModifier? {
        modifierBindings.first { $0.value == presetID }?.key
    }

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - UI Navigation (runtime-only)

    var pendingSettingsTab: SettingsTab?

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
        self.maximumRecordingDuration = defaults.object(forKey: "maximumRecordingDuration") as? TimeInterval ?? 120
        self.selectedInputDeviceUID = defaults.string(forKey: "selectedInputDeviceUID")

        self.fileTranscriptOutputLocation = FileTranscriptOutputLocation(
            rawValue: defaults.string(forKey: "fileTranscriptOutputLocation") ?? ""
        ) ?? .alongsideSource
        if let path = defaults.string(forKey: "fileTranscriptOutputFolder") {
            self.fileTranscriptOutputFolder = URL(fileURLWithPath: path)
        } else {
            self.fileTranscriptOutputFolder = nil
        }
        self.fileTranscriptionPresetID = UUID(uuidString: defaults.string(forKey: "fileTranscriptionPresetID") ?? "")
            ?? DictationPreset.plain.id

        self.selectedLLMProvider = LLMProviderType(rawValue: defaults.string(forKey: "selectedLLMProvider") ?? "") ?? .appleIntelligence
        self.ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self.ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
        self.claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-sonnet-4-20250514"
        self.openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o"

        self.activePresetID = UUID(uuidString: defaults.string(forKey: "activePresetID") ?? "") ?? DictationPreset.defaultPresetID
        self.presets = Self.mergeBuiltInPresets(saved: Self.loadPresets())
        self.modifierBindings = Self.loadModifierBindings()
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")

        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - Launch at Login

    func syncLaunchAtLogin() {
        let enabled = (SMAppService.mainApp.status == .enabled)
        if enabled != launchAtLogin {
            isSyncingLaunchAtLogin = true
            launchAtLogin = enabled
            isSyncingLaunchAtLogin = false
        }
    }

    private func applyLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        do {
            if enable {
                try service.register()
                logger.info("Registered for launch at login")
            } else {
                try service.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Launch-at-login \(enable ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            isSyncingLaunchAtLogin = true
            launchAtLogin = !enable
            isSyncingLaunchAtLogin = false
        }
    }

    // MARK: - Persistence

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: "presets")
    }

    private func saveModifierBindings() {
        let serialisable = Dictionary(uniqueKeysWithValues: modifierBindings.map { ($0.key.rawValue, $0.value.uuidString) })
        defaults.set(serialisable, forKey: "modifierBindings")
    }

    private func pruneOrphanBindings() {
        let validIDs = Set(presets.map(\.id))
        let cleaned = modifierBindings.filter { validIDs.contains($0.value) }
        if cleaned.count != modifierBindings.count {
            modifierBindings = cleaned
        }
    }

    private static func loadModifierBindings() -> [CapsModifier: UUID] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "modifierBindings") as? [String: String] else { return [:] }
        var result: [CapsModifier: UUID] = [:]
        for (key, value) in raw {
            if let mod = CapsModifier(rawValue: key), let id = UUID(uuidString: value) {
                result[mod] = id
            }
        }
        return result
    }

    private static func mergeBuiltInPresets(saved: [DictationPreset]?) -> [DictationPreset] {
        guard var presets = saved else { return DictationPreset.builtInPresets }
        let existingIDs = Set(presets.map(\.id))
        for builtIn in DictationPreset.builtInPresets where !existingIDs.contains(builtIn.id) {
            presets.append(builtIn)
        }
        return presets
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

enum FileTranscriptOutputLocation: String, CaseIterable, Identifiable, Codable {
    case alongsideSource
    case customFolder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alongsideSource: return "Next to the source file"
        case .customFolder: return "Custom folder"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk: return "Push to Talk (hold to listen)"
        case .toggle: return "Toggle (press to start/stop)"
        }
    }
}
