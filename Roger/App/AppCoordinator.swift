import CoreAudio
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AppCoordinator")

@MainActor
@Observable
final class AppCoordinator {
    let appState = AppState()
    let permissionManager = PermissionManager()
    let audioCaptureService = AudioCaptureService()
    let transcriptionEngine = TranscriptionEngine()
    let postProcessor = PostProcessor()
    let textInsertionService = TextInsertionService()
    let hotkeyManager = HotkeyManager()
    let floatingPanel = FloatingPanel()
    let audioLevelMeter = AudioLevelMeter()

    var hotkeyActive = false
    var isSettingUpModel = false
    private(set) var activeRecordingPresetID: UUID?
    private(set) var recordingStartTime: Date?
    private var isWarmingUp = false
    private var maxDurationTask: Task<Void, Never>?
    private var streamingSessionActive = false
    /// Timestamp of the last moment the CoreAudio input HAL was definitely
    /// engaged (warm-up finished or a streaming session started/ended). Used
    /// to decide whether the next `startDictation` needs a pre-flight warm.
    /// Corporate / MDM-managed Macs put the HAL back to sleep within seconds
    /// of idleness, which silently delivers zero samples on the next press.
    private var lastMicActivity: Date?
    /// Pre-flight warm threshold. Aggressive on purpose — the 500 ms warm
    /// latency is hidden behind the floating indicator, and the downside of
    /// under-warming on a sleep-happy HAL is a silent "No speech detected".
    private static let staleMicThreshold: TimeInterval = 5

    init() {
        setupHotkeyCallbacks()
        setupPermissionCallbacks()
        transcriptionEngine.onLevelUpdate = { [weak self] raw in
            Task { @MainActor in self?.audioLevelMeter.ingest(raw: raw) }
        }
    }

    private func setupPermissionCallbacks() {
        permissionManager.onAccessibilityGranted = { [weak self] in
            guard let self, !self.hotkeyActive else { return }
            logger.info("Accessibility permission granted — auto-starting hotkey")
            self.startHotkey()
        }
        permissionManager.onMicrophoneGranted = { [weak self] in
            guard let self else { return }
            logger.info("Microphone permission granted — warming up input HAL")
            Task { await self.warmUpMicrophone() }
        }
    }

    private func setupHotkeyCallbacks() {
        hotkeyManager.onRecordingStarted = { [weak self] modifier in
            Task { @MainActor in
                await self?.startDictation(modifier: modifier)
            }
        }
        hotkeyManager.onRecordingStopped = { [weak self] in
            Task { @MainActor in
                self?.stopDictation()
            }
        }
        hotkeyManager.onRotatePreset = { [weak self] direction in
            Task { @MainActor in
                self?.rotatePreset(direction: direction)
            }
        }
    }

    // MARK: - Preset Rotation

    func rotatePreset(direction: PresetRotationDirection) {
        guard appState.dictationState == .listening else { return }
        let list = appState.presets.filter { !$0.excludedFromRotation }
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex { $0.id == activeRecordingPresetID } ?? -1
        let nextIndex: Int
        switch direction {
        case .next:
            nextIndex = (currentIndex + 1) % list.count
        case .previous:
            nextIndex = currentIndex <= 0 ? list.count - 1 : currentIndex - 1
        }
        activeRecordingPresetID = list[nextIndex].id
        logger.debug("Rotated preset to \(list[nextIndex].name)")
    }

    // MARK: - Hotkey

    func startHotkey() {
        permissionManager.checkAccessibility()
        guard permissionManager.accessibilityAuthorized else {
            logger.warning("Accessibility not authorized — hotkey cannot start")
            hotkeyActive = false
            return
        }
        hotkeyActive = hotkeyManager.start(mode: appState.activationMode)
        if hotkeyActive {
            logger.info("Hotkey started successfully")
        } else {
            logger.error("Hotkey failed to start — event tap creation failed")
        }
    }

    // MARK: - Dictation

    func startDictation(modifier: CapsModifier? = nil) async {
        if case .error = appState.dictationState {
            appState.dictationState = .idle
        }

        guard appState.dictationState == .idle else {
            logger.warning("Cannot start dictation: state is \(self.appState.statusText)")
            return
        }

        guard permissionManager.microphoneAuthorized else {
            appState.dictationState = .error("Microphone access required — open Settings > Permissions")
            return
        }

        guard transcriptionEngine.isReady else {
            appState.dictationState = .error("Speech model not ready — download it in Settings > Model")
            return
        }

        let resolvedPresetID: UUID
        if let modifier, let boundID = appState.modifierBindings[modifier] {
            resolvedPresetID = boundID
        } else {
            resolvedPresetID = appState.activePresetID
        }
        activeRecordingPresetID = resolvedPresetID
        let presetName = appState.presets.first { $0.id == resolvedPresetID }?.name ?? "Polished"

        do {
            audioLevelMeter.reset()
            appState.dictationState = .listening
            recordingStartTime = Date()
            floatingPanel.show(coordinator: self)

            let deviceUID = appState.selectedInputDeviceUID
            await preflightWarmIfStale(deviceUID: deviceUID)

            let deviceID = deviceUID.flatMap { AudioDeviceLookup.deviceID(forUID: $0) }
            try await transcriptionEngine.startStreaming(
                mode: appState.transcriptionMode,
                inputDeviceID: deviceID
            )
            lastMicActivity = Date()
            streamingSessionActive = true

            scheduleMaxDurationStop()
            logger.info("Dictation started (preset: \(presetName))")
        } catch {
            floatingPanel.hide()
            audioLevelMeter.reset()
            activeRecordingPresetID = nil
            streamingSessionActive = false
            await transcriptionEngine.cancelStreaming()
            logger.error("Failed to start streaming transcription: \(error)")
            appState.dictationState = .error("Failed to start recording")
        }
    }

    private func scheduleMaxDurationStop() {
        maxDurationTask?.cancel()
        let cap = appState.maximumRecordingDuration
        maxDurationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.appState.dictationState == .listening {
                logger.info("Max recording duration (\(cap)s) reached — auto-stopping")
                self.stopDictation()
            }
        }
    }

    private func cancelMaxDurationTask() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
    }

    func stopDictation() {
        guard appState.dictationState == .listening else { return }

        cancelMaxDurationTask()
        streamingSessionActive = false

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        guard duration >= appState.minimumRecordingDuration else {
            logger.info("Recording too short (\(String(format: "%.1f", duration), privacy: .public)s), discarding")
            Task { await self.transcriptionEngine.cancelStreaming() }
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .idle
            activeRecordingPresetID = nil
            lastMicActivity = Date()
            return
        }

        logger.notice("Recording complete: \(String(format: "%.1f", duration), privacy: .public)s")
        Task {
            await self.runPipeline(audioSeconds: duration) {
                try await self.transcriptionEngine.finishStreaming()
            }
        }
    }

    private func runPipeline(
        audioSeconds: Double,
        transcribe: @escaping () async throws -> TranscriptionEngine.TranscriptionResult
    ) async {
        appState.dictationState = .transcribing
        defer { activeRecordingPresetID = nil }

        let pipelineStart = Date()

        do {
            let whisperStart = Date()
            let result = try await transcribe()
            let whisperMs = Date().timeIntervalSince(whisperStart) * 1000
            lastMicActivity = Date()

            guard !result.text.isEmpty else {
                let uid = appState.selectedInputDeviceUID ?? "automatic"
                let deviceResolved = appState.selectedInputDeviceUID.map { AudioDeviceLookup.deviceID(forUID: $0) != nil } ?? true
                logger.error("Empty transcription after \(String(format: "%.1f", audioSeconds), privacy: .public)s — input UID \(uid, privacy: .public) (resolved: \(deviceResolved, privacy: .public)), peak energy \(String(format: "%.3f", self.transcriptionEngine.lastStreamPeakEnergy), privacy: .public). If peak is ~0 the HAL delivered no samples — check Privacy & Security > Microphone for Roger.")
                floatingPanel.hide()
                audioLevelMeter.reset()
                appState.dictationState = .error("No speech detected — try speaking louder or closer to the mic")
                return
            }

            let activePreset = appState.presets.first { $0.id == activeRecordingPresetID } ?? appState.activePreset
            var processedText = result.text

            // Determine language for AI prompt context
            let languageName = result.detectedLanguage ?? appState.transcriptionMode.languageHint ?? "the original language"

            let llmStart = Date()
            if activePreset.requiresAI {
                appState.dictationState = .processing
                let llmService = appState.currentLLMService()

                if await llmService.isAvailable {
                    do {
                        processedText = try await postProcessor.process(result.text, preset: activePreset, language: languageName, llmService: llmService)
                    } catch LLMError.guardrailViolation {
                        // Apple Intelligence's on-device safety filter flagged the
                        // text. Rerun the deterministic steps, stash the result
                        // in `lastTranscription` for manual copy and bail out —
                        // pasting unprocessed dictation into the focused app
                        // would surprise the user.
                        logger.warning("AI guardrail blocked — falling back to non-AI pipeline, skipping insertion")
                        let fallback = Self.nonAIFallback(from: activePreset)
                        let safeText = (try? await postProcessor.process(result.text, preset: fallback, language: languageName, llmService: nil)) ?? result.text
                        appState.lastTranscription = safeText
                        floatingPanel.hide()
                        audioLevelMeter.reset()
                        appState.dictationState = .error("AI declined this dictation — copy the transcript from the menu bar")
                        return
                    }
                } else {
                    logger.warning("LLM provider not available, applying non-AI steps only")
                    let fallbackPreset = Self.nonAIFallback(from: activePreset)
                    processedText = try await postProcessor.process(result.text, preset: fallbackPreset, language: languageName, llmService: nil)
                }
            } else {
                processedText = try await postProcessor.process(result.text, preset: activePreset, language: languageName, llmService: nil)
            }
            let llmMs = Date().timeIntervalSince(llmStart) * 1000

            appState.dictationState = .inserting
            appState.lastTranscription = processedText

            let textToInsert = processedText + activePreset.trailingCharacter.character
            let insertStart = Date()
            try textInsertionService.insertText(
                textToInsert,
                restoreClipboard: appState.restoreClipboard
            )

            if activePreset.sendReturnAfterInsert {
                // Brief delay so the focused app processes the insertion before Return fires.
                try? await Task.sleep(nanoseconds: 100_000_000)
                textInsertionService.simulateReturn()
            }
            let insertMs = Date().timeIntervalSince(insertStart) * 1000
            let totalMs = Date().timeIntervalSince(pipelineStart) * 1000

            logger.notice("Dictation timings: audio=\(String(format: "%.1fs", audioSeconds), privacy: .public) whisper=\(String(format: "%.0fms", whisperMs), privacy: .public) llm=\(String(format: "%.0fms", llmMs), privacy: .public) insert=\(String(format: "%.0fms", insertMs), privacy: .public) total=\(String(format: "%.0fms", totalMs), privacy: .public)")
            logger.info("Dictation complete: \(processedText.prefix(50))…")
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .idle
        } catch {
            logger.error("Dictation failed: \(error)")
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .error(error.localizedDescription)
        }
    }

    /// Returns a copy of `preset` with every AI step disabled — used when the
    /// configured LLM provider is unavailable or refuses to process the text.
    private static func nonAIFallback(from preset: DictationPreset) -> DictationPreset {
        DictationPreset(
            id: preset.id, name: preset.name, isBuiltIn: preset.isBuiltIn,
            enableFillerRemoval: preset.enableFillerRemoval,
            enableDedup: preset.enableDedup,
            enableAIFormatting: false,
            enableCustomDictionary: preset.enableCustomDictionary,
            enableRewrite: false,
            aiPrompt: "", rewritePrompt: "",
            dictionaryEntries: preset.dictionaryEntries
        )
    }

    // MARK: - Model Setup

    func setupModel() async {
        guard !isSettingUpModel else {
            logger.info("Model setup already in progress, skipping")
            return
        }
        let mode = appState.transcriptionMode
        guard !transcriptionEngine.isReady(for: mode) else {
            logger.info("Model already ready for \(mode.displayName), skipping setup")
            return
        }

        isSettingUpModel = true

        do {
            try await transcriptionEngine.setup(mode: mode) { _ in }
            isSettingUpModel = false
            logger.info("Model setup complete")
        } catch {
            logger.error("Model setup failed: \(error)")
            isSettingUpModel = false
            appState.dictationState = .error("Model download failed — check your connection and retry")
        }
    }

    // MARK: - Microphone Warm-Up

    /// Fires a brief silent capture so the CoreAudio HAL is warm before the
    /// user's first real Caps Lock press. Safe to call repeatedly — re-entrant
    /// calls are coalesced.
    func warmUpMicrophone() async {
        guard permissionManager.microphoneAuthorized else { return }
        guard !isWarmingUp else { return }
        guard appState.dictationState == .idle else { return }
        isWarmingUp = true
        defer { isWarmingUp = false }
        audioCaptureService.preferredInputUID = appState.selectedInputDeviceUID
        await audioCaptureService.warmUp()
        lastMicActivity = Date()
    }

    /// Runs a brief silent capture to wake the HAL iff it's been idle long
    /// enough that it's likely asleep. Safe inside `startDictation` — shares
    /// the `isWarmingUp` re-entry flag with `warmUpMicrophone()` so the two
    /// can't collide. Caller passes the already-resolved device UID so a
    /// mid-warm device switch can't split the warm and the stream onto
    /// different inputs.
    private func preflightWarmIfStale(deviceUID: String?) async {
        if let last = lastMicActivity,
           Date().timeIntervalSince(last) < Self.staleMicThreshold {
            return
        }
        guard !isWarmingUp else { return }
        isWarmingUp = true
        defer { isWarmingUp = false }
        audioCaptureService.preferredInputUID = deviceUID
        let started = Date()
        await audioCaptureService.warmUp()
        lastMicActivity = Date()
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        logger.info("Pre-flight warm (\(String(format: "%.0f", elapsedMs), privacy: .public)ms) before stream start")
        // Let the AudioUnit graph fully tear down before WhisperKit rebuilds
        // it on the same device — otherwise the first ~100 ms of the stream
        // can come through silent.
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Error Management

    func dismissError() {
        appState.dictationState = .idle
    }
}
