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

    var hotkeyActive = false
    var isSettingUpModel = false
    private(set) var activeRecordingPresetID: UUID?
    private(set) var recordingStartTime: Date?
    private var isWarmingUp = false
    private var maxDurationTask: Task<Void, Never>?
    private var streamingSessionActive = false

    init() {
        setupHotkeyCallbacks()
        setupPermissionCallbacks()
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
            appState.dictationState = .listening
            recordingStartTime = Date()
            floatingPanel.show(coordinator: self)

            let useStreaming = appState.enableStreamingTranscription && transcriptionEngine.isReady
            if useStreaming {
                let deviceID = appState.selectedInputDeviceUID.flatMap { AudioDeviceLookup.deviceID(forUID: $0) }
                try await startStreamingSession(deviceID: deviceID)
            } else {
                audioCaptureService.preferredInputUID = appState.selectedInputDeviceUID
                try audioCaptureService.startCapture()
            }

            scheduleMaxDurationStop()
            logger.info("Dictation started (preset: \(presetName), streaming: \(useStreaming))")
        } catch {
            floatingPanel.hide()
            activeRecordingPresetID = nil
            streamingSessionActive = false
            await transcriptionEngine.cancelStreaming()
            logger.error("Failed to start capture: \(error)")
            appState.dictationState = .error("Failed to start recording")
        }
    }

    private func startStreamingSession(deviceID: AudioDeviceID?) async throws {
        try await transcriptionEngine.startStreaming(
            mode: appState.transcriptionMode,
            inputDeviceID: deviceID
        )
        streamingSessionActive = true
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

        if streamingSessionActive {
            streamingSessionActive = false
            let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
            recordingStartTime = nil

            guard duration >= appState.minimumRecordingDuration else {
                logger.info("Streaming recording too short (\(String(format: "%.1f", duration))s), discarding")
                Task { await self.transcriptionEngine.cancelStreaming() }
                floatingPanel.hide()
                appState.dictationState = .idle
                activeRecordingPresetID = nil
                return
            }

            let mode = appState.transcriptionMode
            Task {
                await self.runPipeline(audioSeconds: duration) {
                    let result = try await self.transcriptionEngine.finishStreaming()
                    // Streaming doesn't always return a detected language — fall back.
                    if result.detectedLanguage == nil {
                        return TranscriptionEngine.TranscriptionResult(text: result.text, detectedLanguage: mode.languageHint)
                    }
                    return result
                }
            }
            return
        }

        let audioBuffer = audioCaptureService.stopCapture()
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        guard duration >= appState.minimumRecordingDuration else {
            logger.info("Recording too short (\(String(format: "%.1f", duration))s), discarding")
            floatingPanel.hide()
            appState.dictationState = .idle
            activeRecordingPresetID = nil
            return
        }

        guard let audioBuffer else {
            let uid = appState.selectedInputDeviceUID ?? "automatic"
            logger.warning("No audio captured (duration: \(String(format: "%.1f", duration))s, input: \(uid)) — likely device warm-up")
            floatingPanel.hide()
            appState.dictationState = .error("No audio captured — your microphone may still be waking up. Try again.")
            activeRecordingPresetID = nil
            return
        }

        logger.notice("Recording complete: \(String(format: "%.1f", duration))s, \(audioBuffer.count) samples")

        let mode = appState.transcriptionMode
        let audioSeconds = Double(audioBuffer.count) / AudioCaptureService.targetSampleRate
        Task {
            await self.runPipeline(audioSeconds: audioSeconds) {
                try await self.transcriptionEngine.transcribe(audioBuffer: audioBuffer, mode: mode)
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

            guard !result.text.isEmpty else {
                logger.warning("Empty transcription — no speech detected")
                floatingPanel.hide()
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
                    processedText = try await postProcessor.process(result.text, preset: activePreset, language: languageName, llmService: llmService)
                } else {
                    logger.warning("LLM provider not available, applying non-AI steps only")
                    let fallbackPreset = DictationPreset(
                        id: activePreset.id, name: activePreset.name, isBuiltIn: activePreset.isBuiltIn,
                        enableFillerRemoval: activePreset.enableFillerRemoval,
                        enableDedup: activePreset.enableDedup,
                        enableAIFormatting: false,
                        enableCustomDictionary: activePreset.enableCustomDictionary,
                        enableRewrite: false,
                        aiPrompt: "", rewritePrompt: "",
                        dictionaryEntries: activePreset.dictionaryEntries
                    )
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

            logger.notice("Dictation timings: audio=\(String(format: "%.1fs", audioSeconds)) whisper=\(String(format: "%.0fms", whisperMs)) llm=\(String(format: "%.0fms", llmMs)) insert=\(String(format: "%.0fms", insertMs)) total=\(String(format: "%.0fms", totalMs))")
            logger.info("Dictation complete: \(processedText.prefix(50))…")
            floatingPanel.hide()
            appState.dictationState = .idle
        } catch {
            logger.error("Dictation failed: \(error)")
            floatingPanel.hide()
            appState.dictationState = .error(error.localizedDescription)
        }
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
    }

    // MARK: - Error Management

    func dismissError() {
        appState.dictationState = .idle
    }
}
