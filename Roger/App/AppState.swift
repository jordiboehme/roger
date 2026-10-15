import Foundation
import Observation
import ServiceManagement
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
    /// The `.md` written by the last log entry, nil after a normal dictation.
    var lastLogEntryURL: URL?

    // MARK: - General Settings

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

    /// Microphones in the order Roger tries them. Always holds `.systemDefault` once.
    var inputPriority: [InputChoice] {
        didSet {
            if let data = try? JSONEncoder().encode(inputPriority) { defaults.set(data, forKey: "inputPriority") }
        }
    }

    /// The UID to record from right now, nil for the system default.
    /// Asks Core Audio: call it when a recording starts, never in a view body.
    var resolvedInputDeviceUID: String? {
        AudioDeviceLookup.resolveInput(inputPriority)
    }

    // MARK: - File Transcription Settings

    var fileTranscriptOutputLocation: FileTranscriptOutputLocation {
        didSet { defaults.set(fileTranscriptOutputLocation.rawValue, forKey: "fileTranscriptOutputLocation") }
    }
    /// Preset used to post-process dropped-file transcripts. Constrained to
    /// presets that don't require an LLM — file transcription should never
    /// silently reach out to an AI provider.
    var fileTranscriptionPresetID: UUID {
        didSet { defaults.set(fileTranscriptionPresetID.uuidString, forKey: "fileTranscriptionPresetID") }
    }
    var fileTranscriptionDiarize: Bool {
        didSet { defaults.set(fileTranscriptionDiarize, forKey: "fileTranscriptionDiarize") }
    }

    // MARK: - Library Settings

    /// Root of the library (Logs, Meetings, Transcripts). nil resolves to
    /// `~/Documents/Roger/`.
    var libraryRoot: URL? {
        didSet {
            if let url = libraryRoot {
                defaults.set(url.path, forKey: "libraryRoot")
            } else {
                defaults.removeObject(forKey: "libraryRoot")
            }
        }
    }

    var libraryLayout: LibraryLayout {
        LibraryLayout(root: libraryRoot ?? LibraryLayout.defaultRoot)
    }

    /// Older folders that still hold meetings or transcripts. Scanned for
    /// unfinished meetings and listed in Settings > Library & Meetings.
    var extraScanFolders: [URL] {
        didSet { defaults.set(extraScanFolders.map(\.path), forKey: "extraScanFolders") }
    }

    /// App version for which the "agent skill outdated" popover hint was closed.
    var agentSkillHintDismissedVersion: String? {
        didSet { defaults.set(agentSkillHintDismissedVersion, forKey: "agentSkillHintDismissedVersion") }
    }

    /// When false, mic.m4a and system.m4a are deleted once the meeting
    /// transcript is written.
    var keepMeetingAudio: Bool {
        didSet { defaults.set(keepMeetingAudio, forKey: "keepMeetingAudio") }
    }

    /// Folder paths of unfinished meetings the user dismissed from the
    /// recovery banner. Pruned on launch when a folder no longer exists.
    var dismissedMeetingSessions: [String] {
        didSet { defaults.set(dismissedMeetingSessions, forKey: "dismissedMeetingSessions") }
    }

    /// Set once the one-time move into the library has run (or was declined).
    var libraryMigrationDone: Bool {
        didSet { defaults.set(libraryMigrationDone, forKey: "libraryMigrationDone") }
    }

    /// Pre-library meetings folder setting, read by the migration only.
    var legacyMeetingRecordingsFolder: URL? {
        defaults.string(forKey: "meetingRecordingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Pre-library custom folder for file transcripts, read by the migration only.
    var legacyFileTranscriptFolder: URL? {
        defaults.string(forKey: "fileTranscriptOutputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - Meeting Recording Settings

    /// How often the per-track CAF chunk file is rolled. Caps long-meeting
    /// memory growth and bounds blast radius from a mid-recording crash.
    var meetingMaxSegmentMinutes: Int {
        didSet { defaults.set(meetingMaxSegmentMinutes, forKey: "meetingMaxSegmentMinutes") }
    }
    /// When true, the system track is run through the diarizer so remote
    /// participants land as Other 1, Other 2 … in the transcript. When false,
    /// every system-side paragraph collapses to a single Other label.
    var meetingDiarizeSystem: Bool {
        didSet { defaults.set(meetingDiarizeSystem, forKey: "meetingDiarizeSystem") }
    }
    /// When true, the mic track is also run through the diarizer so additional
    /// in-room speakers can be detected. The cluster with the most speech is
    /// labelled `Me`; the rest pool into the unified `Other N` namespace
    /// shared with the system track. Off by default — diarising the mic adds
    /// one extra diarization pass on finalisation, only useful for
    /// shared-mic setups (laptop on a meeting-room table, etc.).
    var meetingDiarizeMic: Bool {
        didSet { defaults.set(meetingDiarizeMic, forKey: "meetingDiarizeMic") }
    }
    /// Preset used to post-process meeting transcripts (filler removal,
    /// dedup, custom dictionary, per-preset language pin). Constrained to
    /// presets without AI steps — meeting transcripts must never silently
    /// reach an LLM.
    var meetingTranscriptionPresetID: UUID {
        didSet { defaults.set(meetingTranscriptionPresetID.uuidString, forKey: "meetingTranscriptionPresetID") }
    }

    /// Resolves `meetingTranscriptionPresetID` to a live preset, guaranteed
    /// to have no AI steps enabled. Falls back to Plain if the stored
    /// preset was deleted or accidentally flipped to require AI.
    var meetingTranscriptionPreset: DictationPreset {
        DictationPreset.localPreset(id: meetingTranscriptionPresetID, in: presets)
    }

    /// Resolves `fileTranscriptionPresetID` to a live preset, guaranteeing no
    /// AI steps are enabled. Falls back to Plain if the configured preset was
    /// deleted or accidentally flipped to require AI.
    var fileTranscriptionPreset: DictationPreset {
        DictationPreset.localPreset(id: fileTranscriptionPresetID, in: presets)
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

    // MARK: - Commands

    /// Settings > Commands, in list order.
    var commands: [AgentCommand] {
        didSet {
            if let data = try? JSONEncoder().encode(commands) { defaults.set(data, forKey: "commands") }
        }
    }
    /// Runs after a meeting transcript is written. Nil runs nothing.
    var meetingCommandID: UUID? {
        didSet { defaults.set(meetingCommandID?.uuidString, forKey: "meetingCommandID") }
    }
    /// Runs after a file transcript is written. Nil runs nothing.
    var fileTranscriptCommandID: UUID? {
        didSet { defaults.set(fileTranscriptCommandID?.uuidString, forKey: "fileTranscriptCommandID") }
    }

    func command(id: UUID?) -> AgentCommand? {
        guard let id else { return nil }
        return commands.first { $0.id == id }
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

    var activePreset: DictationPreset {
        presets.first { $0.id == activePresetID } ?? .polished
    }

    // MARK: - Computed

    /// Effective transcription language: the preset's pin, or nil to let
    /// Parakeet v3 auto-detect.
    func resolvedLanguage(for preset: DictationPreset) -> String? {
        preset.language
    }

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
        self.activationMode = ActivationMode(rawValue: defaults.string(forKey: "activationMode") ?? "") ?? .pushToTalk
        self.restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        self.minimumRecordingDuration = defaults.object(forKey: "minimumRecordingDuration") as? TimeInterval ?? 1.5
        let storedMaximum = defaults.object(forKey: "maximumRecordingDuration") as? TimeInterval
        let maximum = RecordingDurationMigration.migrated(
            stored: storedMaximum,
            migrated: defaults.bool(forKey: RecordingDurationMigration.migratedKey)
        )
        self.maximumRecordingDuration = maximum.value
        if maximum.value != storedMaximum { defaults.set(maximum.value, forKey: "maximumRecordingDuration") }
        if !defaults.bool(forKey: RecordingDurationMigration.migratedKey) {
            defaults.set(true, forKey: RecordingDurationMigration.migratedKey)
        }
        let inputs = InputChoice.load(
            stored: defaults.data(forKey: "inputPriority"),
            legacyUID: defaults.string(forKey: "selectedInputDeviceUID"),
            nameForUID: { uid in AudioDeviceLookup.availableInputs().first { $0.id == uid }?.name }
        )
        self.inputPriority = inputs.list
        if inputs.write {
            // didSet does not run in init.
            if let data = try? JSONEncoder().encode(inputs.list) { defaults.set(data, forKey: "inputPriority") }
            defaults.removeObject(forKey: "selectedInputDeviceUID")
        }

        self.fileTranscriptOutputLocation = FileTranscriptOutputLocation(
            rawValue: defaults.string(forKey: "fileTranscriptOutputLocation") ?? ""
        ) ?? .library
        self.fileTranscriptionPresetID = UUID(uuidString: defaults.string(forKey: "fileTranscriptionPresetID") ?? "")
            ?? DictationPreset.plain.id
        self.fileTranscriptionDiarize = defaults.bool(forKey: "fileTranscriptionDiarize")

        self.libraryRoot = defaults.string(forKey: "libraryRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.extraScanFolders = (defaults.stringArray(forKey: "extraScanFolders") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.agentSkillHintDismissedVersion = defaults.string(forKey: "agentSkillHintDismissedVersion")
        self.keepMeetingAudio = defaults.object(forKey: "keepMeetingAudio") as? Bool ?? true
        self.libraryMigrationDone = defaults.bool(forKey: "libraryMigrationDone")
        self.dismissedMeetingSessions = defaults.stringArray(forKey: "dismissedMeetingSessions") ?? []

        let storedSegmentMinutes = defaults.object(forKey: "meetingMaxSegmentMinutes") as? Int
        self.meetingMaxSegmentMinutes = storedSegmentMinutes ?? 30
        let storedDiarizeSystem = defaults.object(forKey: "meetingDiarizeSystem") as? Bool
        self.meetingDiarizeSystem = storedDiarizeSystem ?? true
        let storedDiarizeMic = defaults.object(forKey: "meetingDiarizeMic") as? Bool
        self.meetingDiarizeMic = storedDiarizeMic ?? false
        self.meetingTranscriptionPresetID = UUID(uuidString: defaults.string(forKey: "meetingTranscriptionPresetID") ?? "")
            ?? DictationPreset.plain.id

        self.selectedLLMProvider = LLMProviderType(rawValue: defaults.string(forKey: "selectedLLMProvider") ?? "") ?? .appleIntelligence
        self.ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self.ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
        self.claudeModel = defaults.string(forKey: "claudeModel") ?? "claude-sonnet-4-20250514"
        self.openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o"

        self.activePresetID = UUID(uuidString: defaults.string(forKey: "activePresetID") ?? "") ?? DictationPreset.defaultPresetID
        self.presets = Self.mergeBuiltInPresets(saved: Self.loadPresets())
        self.modifierBindings = Self.loadModifierBindings()
        self.commands = (defaults.data(forKey: "commands"))
            .flatMap { try? JSONDecoder().decode([AgentCommand].self, from: $0) } ?? []
        self.meetingCommandID = defaults.string(forKey: "meetingCommandID").flatMap(UUID.init(uuidString:))
        self.fileTranscriptCommandID = defaults.string(forKey: "fileTranscriptCommandID").flatMap(UUID.init(uuidString:))
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

enum FileTranscriptOutputLocation: String, CaseIterable, Identifiable, Codable {
    /// `<library>/Transcripts/YYYY/MM/`.
    case library
    case alongsideSource

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .library: return "Roger library"
        case .alongsideSource: return "Next to the source file"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    /// Segment title in Settings > General.
    var title: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .toggle: return "Toggle"
        }
    }

    /// Note under the Mode row.
    var note: String {
        switch self {
        case .pushToTalk: return "Hold the dictation key while you speak."
        case .toggle: return "Press the dictation key to start. Press it again to stop."
        }
    }
}

/// The default for the maximum recording duration went from 120 to 300
/// seconds. The decision is a pure function so tests need no `AppState`.
enum RecordingDurationMigration {
    static let migratedKey = "maximumRecordingDurationMigrated300"
    static let defaultDuration: TimeInterval = 300
    private static let oldDefault: TimeInterval = 120

    /// Nothing stored gets the default. A stored 120 (the old default)
    /// becomes 300 once; any other value stays. `migrated` is true after.
    static func migrated(stored: TimeInterval?, migrated: Bool) -> (value: TimeInterval, migrated: Bool) {
        guard let stored else { return (defaultDuration, true) }
        if !migrated, stored == oldDefault { return (defaultDuration, true) }
        return (stored, true)
    }
}
