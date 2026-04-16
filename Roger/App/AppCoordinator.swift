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
    private var isSettingUpModel = false
    private var recordingStartTime: Date?

    init() {
        setupHotkeyCallbacks()
    }

    private func setupHotkeyCallbacks() {
        hotkeyManager.onRecordingStarted = { [weak self] in
            Task { @MainActor in
                self?.startDictation()
            }
        }
        hotkeyManager.onRecordingStopped = { [weak self] in
            Task { @MainActor in
                self?.stopDictation()
            }
        }
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

    func startDictation() {
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

        do {
            appState.dictationState = .listening
            recordingStartTime = Date()
            floatingPanel.show()
            try audioCaptureService.startCapture()
            logger.info("Dictation started")
        } catch {
            floatingPanel.hide()
            logger.error("Failed to start capture: \(error)")
            appState.dictationState = .error("Failed to start recording")
        }
    }

    func stopDictation() {
        guard appState.dictationState == .listening else { return }

        floatingPanel.hide()
        let audioBuffer = audioCaptureService.stopCapture()
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        guard duration >= appState.minimumRecordingDuration else {
            logger.info("Recording too short (\(String(format: "%.1f", duration))s), discarding")
            appState.dictationState = .idle
            return
        }

        guard let audioBuffer else {
            logger.warning("No audio captured")
            appState.dictationState = .idle
            return
        }

        Task {
            await processDictation(audioBuffer: audioBuffer)
        }
    }

    private func processDictation(audioBuffer: [Float]) async {
        appState.dictationState = .transcribing

        do {
            let result = try await transcriptionEngine.transcribe(
                audioBuffer: audioBuffer,
                mode: appState.transcriptionMode
            )

            guard !result.text.isEmpty else {
                logger.info("Empty transcription, skipping")
                appState.dictationState = .idle
                return
            }

            let activePreset = appState.activePreset
            var processedText = result.text

            // Determine language for AI prompt context
            let languageName = result.detectedLanguage ?? appState.transcriptionMode.languageHint ?? "the original language"

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

            appState.dictationState = .inserting
            appState.lastTranscription = processedText

            try textInsertionService.insertText(
                processedText,
                restoreClipboard: appState.restoreClipboard
            )

            logger.info("Dictation complete: \(processedText.prefix(50))…")
            appState.dictationState = .idle
        } catch {
            logger.error("Dictation failed: \(error)")
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
        appState.modelDownloadProgress = 0

        do {
            try await transcriptionEngine.setup(mode: mode) { progress in
                Task { @MainActor [weak self] in
                    self?.appState.modelDownloadProgress = progress
                }
            }
            appState.modelDownloadProgress = nil
            isSettingUpModel = false
            logger.info("Model setup complete")
        } catch {
            logger.error("Model setup failed: \(error)")
            appState.modelDownloadProgress = nil
            isSettingUpModel = false
            appState.dictationState = .error("Model download failed — check your connection and retry")
        }
    }

    // MARK: - Error Management

    func dismissError() {
        appState.dictationState = .idle
    }
}
