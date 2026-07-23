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

    /// System-wide mic mute (Core Audio HAL). Toggled by the standard hotkey
    /// while a meeting recording is active, so muting silences the meeting app
    /// and Roger's own mic.m4a together.
    let systemMicMute: SystemMicMute

    var hotkeyActive = false
    var isSettingUpModel = false
    /// Live download/compile progress while `isSettingUpModel` — nil outside
    /// setup and before the first callback arrives (UI falls back to an
    /// indeterminate spinner for that brief window).
    var modelSetupProgress: ModelSetupProgress?
    var isModelReady = false
    var lastModelError: String? = nil
    private(set) var activeRecordingPresetID: UUID?
    /// Language pin resolved at recording start, applied when the buffer is
    /// transcribed on release.
    private var activeRecordingLanguageOverride: String?
    private(set) var recordingStartTime: Date?
    private var isWarmingUp = false
    private var maxDurationTask: Task<Void, Never>?
    /// Currently-transcribing file, or nil when nothing is in flight. The
    /// floating indicator observes this to show the "Transcribing X" overlay.
    private(set) var activeFileTranscription: FileTranscriptionJob?
    private var fileTranscriptionTask: Task<Void, Never>?
    /// Shared anonymous speaker diarization (file transcription + meetings).
    let diarizationService = DiarizationService()

    /// Meeting recording orchestrator. Builds on Core Audio Process Taps
    /// (macOS 14.4+, the project deployment floor).
    let meetingRecorder: MeetingRecordingService

    /// Recovered sessions from a prior crash (CAF chunks but no transcript).
    /// Populated on launch and surfaced in MenuBarView so the user can
    /// decide whether to finalise.
    private(set) var pendingMeetingSessions: [MeetingSession] = []

    /// Session-scoped flag: true when the user has dismissed the floating
    /// overlay during an active recording. The status-bar item compensates
    /// by showing `record.circle.fill 0:42` so they still see capture is
    /// live. Resets to false on every recording start, stop and recovery.
    var meetingOverlayHidden: Bool = false

    init() {
        // Share one diarization service across file transcription and meetings
        // so its CoreML models load once per launch.
        self.meetingRecorder = MeetingRecordingService(
            appState: appState,
            transcriptionEngine: transcriptionEngine,
            diarization: diarizationService
        )
        self.systemMicMute = SystemMicMute(appState: appState)
        setupHotkeyCallbacks()
        setupPermissionCallbacks()
        audioCaptureService.onLevelUpdate = { [weak self] raw in
            Task { @MainActor in self?.audioLevelMeter.ingest(raw: raw) }
        }
        self.pendingMeetingSessions = self.meetingRecorder.unfinalisedSessions()
        observeRecorderState()
        // HAL mute persists after our process exits, so always restore on quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemMicMute.restoreIfNeeded() }
        }
    }

    /// Keeps the hotkey's mute-toggle mode and the system mute in sync with the
    /// recorder's real state. Covers stops we don't drive directly (e.g. a
    /// sleep-interrupted auto-finalise): when the recorder leaves `.recording`,
    /// disengage the hotkey repurpose and restore the mic.
    private func observeRecorderState() {
        withObservationTracking {
            _ = meetingRecorder.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if case .recording = self.meetingRecorder.state {
                    // still capturing — leave the mute toggle engaged
                } else if self.hotkeyManager.meetingRecordingActive {
                    self.hotkeyManager.meetingRecordingActive = false
                    self.systemMicMute.restoreIfNeeded()
                }
                self.observeRecorderState()
            }
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
        hotkeyManager.onMicMuteToggle = { [weak self] in
            Task { @MainActor in
                self?.toggleMeetingMicMute()
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
            activeRecordingLanguageOverride = languageOverride
            floatingPanel.show(coordinator: self)

            audioCaptureService.preferredInputUID = appState.selectedInputDeviceUID
            try audioCaptureService.startCapture()

            scheduleMaxDurationStop()
            logger.info("Dictation started (preset: \(presetName))")
        } catch {
            floatingPanel.hide()
            audioLevelMeter.reset()
            activeRecordingPresetID = nil
            activeRecordingLanguageOverride = nil
            _ = audioCaptureService.stopCapture()
            logger.error("Failed to start capture: \(error)")
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

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        let samples = audioCaptureService.stopCapture()
        let languageOverride = activeRecordingLanguageOverride
        activeRecordingLanguageOverride = nil

        guard duration >= appState.minimumRecordingDuration else {
            logger.info("Recording too short (\(String(format: "%.1f", duration), privacy: .public)s), discarding")
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .idle
            activeRecordingPresetID = nil
            return
        }

        logger.notice("Recording complete: \(String(format: "%.1f", duration), privacy: .public)s")
        Task {
            await self.runPipeline(audioSeconds: duration) {
                guard let samples, !samples.isEmpty else {
                    return TranscriptionEngine.TranscriptionResult(text: "", detectedLanguage: nil)
                }
                return try await self.transcriptionEngine.transcribe(
                    audioBuffer: samples,
                    languageOverride: languageOverride
                )
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
                let uid = appState.selectedInputDeviceUID ?? "automatic"
                let deviceResolved = appState.selectedInputDeviceUID.map { AudioDeviceLookup.deviceID(forUID: $0) != nil } ?? true
                logger.error("Empty transcription after \(String(format: "%.1f", audioSeconds), privacy: .public)s — input UID \(uid, privacy: .public) (resolved: \(deviceResolved, privacy: .public)). If this persists, check Privacy & Security > Microphone for Roger.")
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
                return "the original language"
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
        guard !transcriptionEngine.isReady else {
            logger.info("Model already ready, skipping setup")
            return
        }

        isSettingUpModel = true
        lastModelError = nil
        modelSetupProgress = nil

        do {
            try await transcriptionEngine.setup { [weak self] progress in
                Task { @MainActor in
                    self?.modelSetupProgress = progress
                }
            }
            isSettingUpModel = false
            modelSetupProgress = nil
            isModelReady = true
            logger.info("Model setup complete")
        } catch {
            logger.error("Model setup failed: \(error)")
            isSettingUpModel = false
            modelSetupProgress = nil
            lastModelError = error.localizedDescription
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

    // MARK: - Model Management

    func uninstallModel() async {
        await transcriptionEngine.uninstall()
        isModelReady = false
        lastModelError = nil
    }

    func reinstallModel() async {
        isModelReady = false
        lastModelError = nil
        await transcriptionEngine.uninstall()
        await setupModel()
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

            let result: TranscriptionEngine.TranscriptionResult
            let processedText: String

            if appState.fileTranscriptionDiarize {
                let detailed = try await transcriptionEngine.transcribeFileDetailed(
                    url: prepared.url,
                    languageOverride: languageOverride
                )
                try Task.checkCancellation()

                let languageName: String = {
                    if let code = detailed.result.detectedLanguage {
                        return WhisperLanguage.displayName(for: code)
                    }
                    return "the original language"
                }()

                // Diarization is best-effort: if model download or inference fails,
                // fall back to the plain transcription rather than surfacing an error.
                let textToParse: String
                do {
                    let aligned = try await diarizationService.speakerSegments(
                        samples: detailed.audioSamples,
                        tokens: detailed.tokenTimings
                    )
                    let diarized = formatDiarized(aligned)
                    textToParse = diarized.isEmpty ? detailed.result.text : diarized
                } catch {
                    logger.warning("Diarization failed, using plain transcript: \(error.localizedDescription, privacy: .public)")
                    textToParse = detailed.result.text
                }

                result = detailed.result
                processedText = try await postProcessor.process(
                    textToParse,
                    preset: preset,
                    language: languageName,
                    llmService: nil
                )
            } else {
                let r = try await transcriptionEngine.transcribeFile(
                    url: prepared.url,
                    languageOverride: languageOverride
                )
                result = r
                try Task.checkCancellation()
                let languageName: String = {
                    if let code = r.detectedLanguage {
                        return WhisperLanguage.displayName(for: code)
                    }
                    return "the original language"
                }()
                processedText = try await postProcessor.process(
                    r.text,
                    preset: preset,
                    language: languageName,
                    llmService: nil
                )
            }

            try Task.checkCancellation()
            _ = result  // silence unused-variable warning; result holds detected language

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

    private func formatDiarized(_ segments: [SpeakerSegment]) -> String {
        var lines: [String] = []
        var currentSpeaker: String? = nil
        var buffer: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, !buffer.isEmpty else { buffer = []; return }
            let label = speaker.hasPrefix("S") ? "Speaker \(speaker.dropFirst())" : speaker
            lines.append("[\(label)]\n\(buffer.joined(separator: " "))")
            buffer = []
        }

        for segment in segments {
            if segment.speakerId != currentSpeaker {
                flush()
                currentSpeaker = segment.speakerId
            }
            buffer.append(segment.text)
        }
        flush()
        return lines.joined(separator: "\n\n")
    }

    private func finishFileTranscription(error: String?) async {
        activeFileTranscription = nil
        fileTranscriptionTask = nil
        floatingPanel.hide()
        if let error {
            appState.dictationState = .error(error)
        }
    }

    // MARK: - Meeting Recording

    /// Starts a meeting recording. Surfaces a structured error in
    /// `appState.dictationState` (the existing alert banner) when
    /// preconditions fail. UI calls this from the menu bar Start row and
    /// from the global hotkey.
    func startMeetingRecording() async {
        guard meetingRecorder.state == .idle else {
            appState.dictationState = .error(MeetingRecordingError.alreadyRecording.errorDescription ?? "")
            return
        }
        guard appState.dictationState == .idle || (appState.dictationState.isErrorState) else {
            appState.dictationState = .error(MeetingRecordingError.dictationActive.errorDescription ?? "")
            return
        }
        guard activeFileTranscription == nil else {
            appState.dictationState = .error(MeetingRecordingError.fileTranscriptionActive.errorDescription ?? "")
            return
        }
        guard permissionManager.microphoneAuthorized else {
            appState.dictationState = .error(MeetingRecordingError.microphonePermissionDenied.errorDescription ?? "")
            return
        }

        if case .error = appState.dictationState {
            appState.dictationState = .idle
        }

        meetingOverlayHidden = false
        do {
            try await meetingRecorder.start()
            floatingPanel.show(coordinator: self)
            // Repurpose the standard hotkey as the mic-mute toggle for the
            // duration of the recording.
            hotkeyManager.meetingRecordingActive = true
            logger.notice("Meeting recording started")
        } catch let error as MeetingRecordingError {
            appState.dictationState = .error(error.errorDescription ?? "Couldn't start meeting recording")
        } catch {
            appState.dictationState = .error(error.localizedDescription)
        }
    }

    /// Stops a meeting recording and runs finalisation off the main actor.
    /// The floating panel is dismissed on entering finalisation; the
    /// Recordings tab will show the result.
    func stopMeetingRecording() async {
        guard meetingRecorder.isActive else { return }
        // Bring the overlay back so the standard "thinking / finalising"
        // state is visible during the post-stop pipeline. The hide
        // affordance is exclusive to the active capture phase.
        if meetingOverlayHidden {
            meetingOverlayHidden = false
            floatingPanel.setMeetingOverlayHidden(false)
        }
        // Disengage the hotkey mute-toggle and restore the mic before tearing
        // down — the toggle control goes away with the recording.
        hotkeyManager.meetingRecordingActive = false
        systemMicMute.restoreIfNeeded()
        await meetingRecorder.stop()
        floatingPanel.hide()
        // Refresh recovery list — a freshly finalised session won't be in
        // it, but a sleep-interrupted one might.
        pendingMeetingSessions = meetingRecorder.unfinalisedSessions()
    }

    /// Toggle visibility of the floating overlay during active capture. No-op
    /// outside of the recording phase so it can't accidentally hide the
    /// finalising / error overlay.
    func setMeetingOverlayHidden(_ hidden: Bool) {
        guard case .recording = meetingRecorder.state else { return }
        meetingOverlayHidden = hidden
        floatingPanel.setMeetingOverlayHidden(hidden)
    }

    /// Toggles the system-level mic mute. Bound to the standard hotkey while a
    /// meeting recording is active (see `HotkeyManager.meetingRecordingActive`),
    /// so muting silences the meeting app and Roger's mic.m4a together.
    func toggleMeetingMicMute() {
        guard meetingRecorder.isActive else { return }
        systemMicMute.toggle()
    }

    /// Toggles the meeting recording state from a hotkey or menu action.
    func toggleMeetingRecording() async {
        if meetingRecorder.isActive {
            await stopMeetingRecording()
        } else {
            await startMeetingRecording()
        }
    }

    /// Re-runs concat + transcription on a session that was interrupted by a
    /// crash. Surfaced from MenuBarView's recovery banner.
    func resumeMeetingFinalisation(_ session: MeetingSession) async {
        meetingOverlayHidden = false
        floatingPanel.show(coordinator: self)
        await meetingRecorder.finaliseRecovered(session)
        floatingPanel.hide()
        // Surface any error from the pipeline (e.g. encode failed, model
        // unavailable) so the user sees why the banner didn't clear. If
        // finalisation succeeded the state is .idle and we don't touch the
        // dictation state.
        if case .error(let recordingError) = meetingRecorder.state {
            appState.dictationState = .error(recordingError.errorDescription ?? "Couldn't finalise meeting")
        }
        pendingMeetingSessions = meetingRecorder.unfinalisedSessions()
    }

    /// Drops a recovered session from the pending list without finalising
    /// (the user opted to discard or handle it manually).
    func dismissPendingMeeting(_ session: MeetingSession) {
        pendingMeetingSessions.removeAll { $0.id == session.id }
    }

    // MARK: - Error Management

    func dismissError() {
        appState.dictationState = .idle
    }
}

private extension AppState.DictationState {
    var isErrorState: Bool {
        if case .error = self { return true }
        return false
    }
}
