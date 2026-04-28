import AppKit
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
    /// Currently-transcribing file, or nil when nothing is in flight. The
    /// floating indicator observes this to show the "Transcribing X" overlay.
    private(set) var activeFileTranscription: FileTranscriptionJob?
    private var fileTranscriptionTask: Task<Void, Never>?

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
        let resolvedPreset = appState.presets.first { $0.id == resolvedPresetID } ?? .polished
        let presetName = resolvedPreset.name
        let languageOverride = appState.resolvedLanguage(for: resolvedPreset)

        do {
            audioLevelMeter.reset()
            appState.dictationState = .listening
            recordingStartTime = Date()
            floatingPanel.show(coordinator: self)

            let deviceID = appState.selectedInputDeviceUID.flatMap { AudioDeviceLookup.deviceID(forUID: $0) }
            try await transcriptionEngine.startStreaming(
                mode: appState.transcriptionMode,
                languageOverride: languageOverride,
                inputDeviceID: deviceID
            )
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

            if let failure = transcriptionEngine.consumeStreamFailure() {
                logger.error("Stream failed to open: \(failure.reason, privacy: .public) on device \(failure.deviceID)")
                floatingPanel.hide()
                audioLevelMeter.reset()
                appState.dictationState = .error("Microphone stream never opened — check Console logs and mic permission")
                return
            }

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
            let languageName: String = {
                if let code = result.detectedLanguage {
                    return WhisperLanguage.displayName(for: code)
                }
                return appState.transcriptionMode.languageHint ?? "the original language"
            }()

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
    }

    // MARK: - File Transcription (drag-and-drop)

    struct FileTranscriptionJob: Sendable, Equatable {
        let sourceURL: URL
        let displayName: String
    }

    /// Entry point for a file dropped on the menu bar icon. Rejected if
    /// another transcription (hotkey or file) is already running, or the
    /// model isn't ready.
    func handleDroppedMediaFile(url: URL) {
        guard activeFileTranscription == nil else {
            logger.info("Dropped file while another file transcription is in flight — ignored: \(url.lastPathComponent, privacy: .public)")
            return
        }
        guard appState.dictationState == .idle || {
            if case .error = appState.dictationState { return true }
            return false
        }() else {
            logger.info("Dropped file while dictation is busy — ignored: \(url.lastPathComponent, privacy: .public)")
            return
        }
        guard transcriptionEngine.isReady else {
            appState.dictationState = .error("Speech model not ready — download it in Settings > Model")
            return
        }

        // Clear any prior error so the user sees the transcription overlay.
        if case .error = appState.dictationState {
            appState.dictationState = .idle
        }

        let job = FileTranscriptionJob(sourceURL: url, displayName: url.lastPathComponent)
        activeFileTranscription = job
        floatingPanel.show(coordinator: self)

        fileTranscriptionTask = Task { [weak self] in
            await self?.runFileTranscription(job: job)
        }
    }

    /// Cancels an in-flight file transcription (triggered by the overlay's
    /// Cancel button). The running Task throws `CancellationError` at the
    /// next `await`; cleanup happens in `runFileTranscription`.
    func cancelFileTranscription() {
        fileTranscriptionTask?.cancel()
    }

    private func runFileTranscription(job: FileTranscriptionJob) async {
        logger.info("File transcription started: \(job.displayName, privacy: .public)")
        var tempURL: URL?
        defer {
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        }

        do {
            let prepared = try await MediaAudioExtractor.prepare(source: job.sourceURL)
            if prepared.isTemporary { tempURL = prepared.url }
            try Task.checkCancellation()

            // File transcripts never run through the LLM — `fileTranscriptionPreset`
            // is guaranteed to have no AI steps enabled (see AppState). Read it
            // up-front so the per-preset language override can flow into Whisper.
            let preset = appState.fileTranscriptionPreset
            let languageOverride = appState.resolvedLanguage(for: preset)
            let result = try await transcriptionEngine.transcribeFile(
                url: prepared.url,
                mode: appState.transcriptionMode,
                languageOverride: languageOverride
            )
            try Task.checkCancellation()
            let languageName: String = {
                if let code = result.detectedLanguage {
                    return WhisperLanguage.displayName(for: code)
                }
                return appState.transcriptionMode.languageHint ?? "the original language"
            }()
            let processedText = try await postProcessor.process(
                result.text,
                preset: preset,
                language: languageName,
                llmService: nil
            )
            try Task.checkCancellation()

            guard !processedText.isEmpty else {
                logger.warning("File transcription produced empty text: \(job.displayName, privacy: .public)")
                await finishFileTranscription(error: "No speech detected in \(job.displayName)")
                return
            }

            let outputURL = try TranscriptOutputWriter.write(
                transcript: processedText,
                source: job.sourceURL,
                location: appState.fileTranscriptOutputLocation,
                customFolder: appState.fileTranscriptOutputFolder
            )
            logger.notice("File transcription saved: \(outputURL.path, privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            await finishFileTranscription(error: nil)
        } catch is CancellationError {
            logger.info("File transcription cancelled: \(job.displayName, privacy: .public)")
            await finishFileTranscription(error: nil)
        } catch {
            logger.error("File transcription failed: \(error.localizedDescription, privacy: .public)")
            await finishFileTranscription(error: error.localizedDescription)
        }
    }

    private func finishFileTranscription(error: String?) async {
        activeFileTranscription = nil
        fileTranscriptionTask = nil
        floatingPanel.hide()
        if let error {
            appState.dictationState = .error(error)
        }
    }

    // MARK: - Error Management

    func dismissError() {
        appState.dictationState = .idle
    }
}
