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

    func startDictation() {
        guard appState.dictationState == .idle else {
            logger.warning("Cannot start dictation: state is \(self.appState.statusText)")
            return
        }

        guard permissionManager.microphoneAuthorized else {
            appState.dictationState = .error("Microphone access required")
            return
        }

        do {
            appState.dictationState = .listening
            recordingStartTime = Date()
            try audioCaptureService.startCapture()
            logger.info("Dictation started")
        } catch {
            logger.error("Failed to start capture: \(error)")
            appState.dictationState = .error("Failed to start recording")
        }
    }

    func stopDictation() {
        guard appState.dictationState == .listening else { return }

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
            let transcript = try await transcriptionEngine.transcribe(
                audioBuffer: audioBuffer,
                language: appState.selectedLanguage
            )

            guard !transcript.isEmpty else {
                logger.info("Empty transcription, skipping")
                appState.dictationState = .idle
                return
            }

            let activePreset = appState.activePreset
            let processedText: String

            if activePreset.requiresAI {
                appState.dictationState = .processing
                let llmService = appState.currentLLMService()
                processedText = try await postProcessor.process(transcript, preset: activePreset, llmService: llmService)
            } else {
                processedText = try await postProcessor.process(transcript, preset: activePreset, llmService: nil)
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

            try? await Task.sleep(for: .seconds(3))
            appState.dictationState = .idle
        }
    }

    func setupModel() async {
        do {
            appState.modelDownloadProgress = 0
            try await transcriptionEngine.setup { progress in
                Task { @MainActor [weak self] in
                    self?.appState.modelDownloadProgress = progress
                }
            }
            appState.modelDownloadProgress = nil
            logger.info("Model setup complete")
        } catch {
            logger.error("Model setup failed: \(error)")
            appState.dictationState = .error("Model download failed")
        }
    }
}
