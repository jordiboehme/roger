import AppKit
import CoreAudio
import FluidAudio
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
    /// True for a short moment after a log entry was saved; the floating
    /// indicator shows "Logged" while it is set.
    private(set) var showsLogSaved = false
    /// A short note shown with "Logged", for example when system audio
    /// could not be recorded. Cleared together with `showsLogSaved`.
    private(set) var logSavedNote: String?
    private var logSavedGeneration = 0
    /// Collects system audio while a log preset with `recordSystemAudio` records.
    private var systemAudioRecorder: SystemAudioRecorder?
    /// The tap failed to start for this log; show the note with "Logged".
    private var systemAudioUnavailable = false
    /// Language pin resolved at recording start, applied when the buffer is
    /// transcribed on release.
    private var activeRecordingLanguageOverride: String?
    /// The input UID the running dictation records from (nil: system
    /// default), resolved once at start. The empty-transcript diagnostic logs it.
    private var activeRecordingInputUID: String?
    private(set) var recordingStartTime: Date?
    private var isWarmingUp = false
    private var warmUpTracker = MicWarmUpTracker()
    private var inputDeviceMonitor: InputDeviceMonitor?
    /// Bumped after every debounced device change, so the Microphone pane can refresh.
    private(set) var inputDevicesGeneration = 0
    private var maxDurationTask: Task<Void, Never>?
    /// Currently-transcribing file, or nil when nothing is in flight. The
    /// floating indicator observes this to show the "Transcribing X" overlay.
    private(set) var activeFileTranscription: FileTranscriptionJob?
    /// A file handed over (Open With, Services) before the speech model was
    /// loaded, for example when that launched Roger. Starts once setup ends.
    private var pendingMediaFile: URL?
    /// 0-1 fraction while a file transcription job is in its speaker
    /// identification phase; nil during ASR and outside file jobs. Drives
    /// the overlay's "Identifying speakers" line.
    private(set) var fileTranscriptionProgress: Double?
    /// True only while the current file job is inside its diarization phase;
    /// gates the `speakerSegments` progress callback so a late in-flight
    /// callback can't repaint the overlay after diarization has ended.
    private var fileTranscriptionDiarizing = false
    private var fileTranscriptionTask: Task<Void, Never>?
    /// Shared anonymous speaker diarization (file transcription + meetings).
    let diarizationService = DiarizationService()
    /// Writes change-log events so agents see new and changed items.
    let libraryChanges = LibraryChangeRecorder()
    /// Runs the commands of Settings > Commands after Roger saved an item.
    let commandScheduler: CommandScheduler
    /// The login-shell search path for commands and "Suggest Commands".
    private let commandSearchPath: CommandSearchPathCache
    private let commandRunner: ProcessCommandRunner
    /// An installed ingest skill is older than the one in this app.
    private(set) var agentSkillOutdated = false

    /// Reads the installed skills (a few small files) off the main actor.
    func checkAgentSkills() {
        guard let skill = BundledSkill.load() else { return }
        let installer = SkillInstaller.live(skill: skill)
        Task {
            let outdated = await Task.detached { installer.anyOutdated() }.value
            agentSkillOutdated = outdated
        }
    }

    /// Meeting recording orchestrator. Builds on Core Audio Process Taps
    /// (macOS 14.4+, below the macOS 15 deployment floor).
    let meetingRecorder: MeetingRecordingService

    /// Unfinished sessions (see `MeetingSessionScanner.isUnfinished`).
    /// Populated on launch and after every finalisation, surfaced in
    /// MenuBarView so the user can decide whether to finalise.
    private(set) var pendingMeetingSessions: [MeetingSession] = []


    /// Session-scoped flag: true when the user has dismissed the floating
    /// overlay during an active recording. The status-bar item compensates
    /// by showing `record.circle.fill 0:42` so they still see capture is
    /// live. Resets to false on every recording start, stop and recovery.
    var meetingOverlayHidden: Bool = false

    /// True while an acceptable image drag hovers the meeting overlay —
    /// drives the drop-target highlight in the floating panel.
    var meetingDropTargetActive: Bool = false

    /// Opens the library window. Set by the AppDelegate, which owns the
    /// window; nil in unit tests.
    @ObservationIgnored var libraryOpener: (@MainActor (URL?) -> Void)?

    /// Opens the library window, with the item at `url` selected when given.
    func openLibrary(selecting url: URL? = nil) {
        libraryOpener?(url)
    }

    /// Opens the settings window. Set by the AppDelegate, which owns the
    /// window; nil in unit tests.
    @ObservationIgnored var settingsOpener: (@MainActor (SettingsPane?) -> Void)?

    /// Opens the settings window on `pane`, or on the last pane when nil.
    func openSettings(_ pane: SettingsPane? = nil) {
        settingsOpener?(pane)
    }

    // MARK: - Commands

    /// Builds the placeholder values for a written Markdown file.
    nonisolated static func commandItemInfo(markdownURL: URL, kind: LibraryItemKind, root: URL) -> CommandItemInfo {
        let subject = ChangeKey.subject(markdownURL: markdownURL, kind: kind, root: root)
        let title = LibraryItemReader.item(markdownAt: markdownURL, fallbackKind: kind)?.title
            ?? markdownURL.deletingPathExtension().lastPathComponent
        return CommandItemInfo(file: markdownURL.path, key: subject.key, title: title, kind: kind.rawValue)
    }

    /// Waits for the change log, then runs `commandID`'s command for the
    /// item. Nil or missing id does nothing.
    func runCommand(_ commandID: UUID?, markdownURL: URL, kind: LibraryItemKind, root: URL) async {
        guard let command = appState.command(id: commandID) else { return }
        // The item must be in the change log before an agent asks get_changes.
        await libraryChanges.waitUntilIdle()
        commandScheduler.trigger(command, item: Self.commandItemInfo(markdownURL: markdownURL, kind: kind, root: root))
    }

    /// "Suggest Commands": the coding agents on this Mac and their servers,
    /// found off the main actor (`claude mcp list` takes a few seconds).
    func commandSuggestions() async -> [CommandSuggestion] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = await commandSearchPath.value(runner: commandRunner, home: home)
        let detector = HarnessServerDetector(home: home, runner: commandRunner, searchPath: path)
        let found = await Task.detached(priority: .userInitiated) { await detector.detect() }.value
        return CommandSuggestions.suggestions(for: found)
    }

    /// The newest item with Markdown in the library, for "Run now". Nil when
    /// the library is empty. Scans the folders off the main actor.
    func newestLibraryItemInfo() async -> CommandItemInfo? {
        let scope = LibraryScanScope(layout: appState.libraryLayout, extraFolders: appState.extraScanFolders)
        let root = appState.libraryLayout.root
        return await Task.detached(priority: .userInitiated) {
            let items = LibraryScanner.scanAll(scope: scope, externalFiles: ExternalTranscriptRegistry.standard.existingFiles())
            guard let newest = items.filter(\.hasMarkdown).max(by: { $0.date < $1.date }),
                  let subject = ChangeKey.subject(for: newest, root: root)
            else { return nil }
            return CommandItemInfo(file: newest.url.path, key: subject.key, title: newest.title, kind: newest.kind.rawValue)
        }.value
    }

    #if DEBUG
    /// How many coordinators this process built. The test host must build none.
    private(set) static var instancesCreated = 0
    #endif

    init() {
        #if DEBUG
        Self.instancesCreated += 1
        #endif
        // FluidAudio's debug lines include recognised words. Keep transcripts
        // out of the console and the system log, even in Debug builds.
        AppLogger.minimumLevel = .info
        // Share one diarization service across file transcription and meetings
        // so its CoreML models load once per launch.
        self.meetingRecorder = MeetingRecordingService(
            appState: appState,
            transcriptionEngine: transcriptionEngine,
            diarization: diarizationService
        )
        self.systemMicMute = SystemMicMute(appState: appState) { [meetingRecorder] in meetingRecorder.activeInputUID }
        let runner = ProcessCommandRunner()
        let searchPath = CommandSearchPathCache()
        self.commandRunner = runner
        self.commandSearchPath = searchPath
        self.commandScheduler = CommandScheduler(
            runner: runner,
            launcher: TerminalLauncher(),
            confirmer: CommandConfirmationPanels(),
            lookup: { [appState] id in appState.command(id: id) },
            environment: {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let path = await searchPath.value(runner: runner, home: home)
                return ["PATH": path.joined(separator: ":"), "HOME": home.path, "USER": NSUserName(), "SHELL": CLILocator.loginShell]
            }
        )
        libraryChanges.environment = { [appState] in
            LibraryChangeEnvironment(
                layout: appState.libraryLayout,
                extraFolders: appState.extraScanFolders,
                externalRegistry: .standard
            )
        }
        meetingRecorder.onTranscriptWritten = { [weak self] url, root in
            guard let self else { return }
            self.libraryChanges.recordWritten(markdownURL: url, kind: .meeting, root: root)
            Task { await self.runCommand(self.appState.meetingCommandID, markdownURL: url, kind: .meeting, root: root) }
        }
        setupHotkeyCallbacks()
        setupPermissionCallbacks()
        audioCaptureService.onLevelUpdate = { [weak self] raw in
            Task { @MainActor in self?.audioLevelMeter.ingest(raw: raw) }
        }
        // Forget dismissals of folders that no longer exist.
        let dismissed = appState.dismissedMeetingSessions
        let stillThere = MeetingSessionScanner.existingFolderPaths(dismissed)
        if stillThere != dismissed { appState.dismissedMeetingSessions = stillThere }
        refreshPendingMeetingSessions()
        observeRecorderState()
        // HAL mute persists after our process exits, so always restore on
        // quit. Running commands are stopped there too.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemMicMute.restoreIfNeeded()
                self?.systemMicMute.reapplyReleasedMute()
                // Headless runs do not outlive Roger.
                self?.commandScheduler.stopAll()
            }
        }
    }

    /// Keeps the hotkey's mute-toggle mode and the system mute in sync with the
    /// recorder's real state. Covers stops we don't drive directly (e.g. a
    /// sleep-interrupted auto-finalise): when the recorder leaves `.recording`,
    /// disengage the hotkey repurpose and restore the mic. When a run ends
    /// (idle or error) the recovery list is refreshed, and an error is shown
    /// in the menu bar unless dictation is busy.
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
                switch self.meetingRecorder.state {
                case .idle:
                    self.refreshPendingMeetingSessions()
                case .error(let recordingError):
                    self.refreshPendingMeetingSessions()
                    if self.appState.dictationState == .idle || self.appState.dictationState.isErrorState {
                        self.appState.dictationState = .error(recordingError.errorDescription ?? "Couldn't finalise meeting")
                    }
                default:
                    break
                }
                self.observeRecorderState()
            }
        }
    }

    // MARK: - Library Migration

    /// One-time move of pre-library meetings into `<library>/Meetings/`.
    /// Asks first. Folders that stay in place become extra scan folders, so
    /// their meetings are still found.
    func runLibraryMigrationIfNeeded() {
        guard !appState.libraryMigrationDone, !meetingRecorder.isActive else { return }
        let layout = appState.libraryLayout
        let input = LibraryMigrationRun.Input(
            layout: layout,
            extraFolders: appState.extraScanFolders,
            legacyTranscriptFolder: appState.legacyFileTranscriptFolder,
            legacyMeetingsFolder: appState.legacyMeetingRecordingsFolder ?? LibraryLayout.legacyRecordingsFolder
        )
        let result = LibraryMigrationRun.run(input) { count, folder in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Move your meetings to the Roger library?"
            alert.informativeText = "Roger now keeps log entries, meetings and transcripts in one folder: \(layout.root.path). Move \(count) \(count == 1 ? "meeting" : "meetings") from \(folder.path) there? If you keep them in place, Roger still finds them."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Keep in Place")
            return alert.runModal() == .alertFirstButtonReturn
        }
        if !result.moved.isEmpty || result.failedCount > 0 {
            logger.notice("Library migration moved \(result.moved.count) meetings, \(result.failedCount) failed")
        }
        appState.extraScanFolders = result.extraFolders
        // Not finished (library folder missing): offered again next launch.
        if result.finished {
            appState.libraryMigrationDone = true
        }
        refreshPendingMeetingSessions()
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
            appState.dictationState = .error("Microphone access required. Open Settings > Permissions.")
            return
        }

        guard transcriptionEngine.isReady else {
            appState.dictationState = .error("Speech model not ready. Download it in Settings > Speech Model.")
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
            cancelLogSavedIndicator()

            // A mic muted at the device level (often left over from an
            // earlier meeting) records pure silence. Lift the mute for this
            // dictation; it is re-applied when the capture ends.
            let inputUID = appState.resolvedInputDeviceUID
            activeRecordingInputUID = inputUID
            systemMicMute.releaseStaleMute(inputUID: inputUID)
            try audioCaptureService.startCapture(inputUID: inputUID)

            systemAudioUnavailable = false
            switch SystemAudioRecorder.plan(
                isLog: resolvedPreset.output == .logEntry,
                recordSystemAudio: resolvedPreset.recordSystemAudio,
                meetingActive: meetingRecorder.isActive
            ) {
            case .off:
                break
            case .unavailable:
                logger.info("Log during a meeting: recording the mic only, the meeting records system audio")
                systemAudioUnavailable = true
            case .record:
                let recorder = SystemAudioRecorder.live()
                do {
                    try recorder.start()
                    systemAudioRecorder = recorder
                } catch {
                    logger.warning("System audio for log unavailable: \(error.localizedDescription, privacy: .public)")
                    systemAudioUnavailable = true
                }
            }

            scheduleMaxDurationStop()
            logger.info("Dictation started (preset: \(presetName))")
        } catch {
            floatingPanel.hide()
            audioLevelMeter.reset()
            activeRecordingPresetID = nil
            activeRecordingLanguageOverride = nil
            activeRecordingInputUID = nil
            _ = audioCaptureService.stopCapture()
            discardSystemAudioRecorder()
            systemMicMute.reapplyReleasedMute()
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

    /// Stops and drops the system audio recorder without using its samples,
    /// so the process tap (and its "Roger Tap" aggregate device) never leaks.
    private func discardSystemAudioRecorder() {
        guard let recorder = systemAudioRecorder else { return }
        systemAudioRecorder = nil
        Task { _ = await recorder.stop() }
    }

    func stopDictation() {
        guard appState.dictationState == .listening else { return }

        cancelMaxDurationTask()

        let endedAt = Date()
        let duration = recordingStartTime.map { endedAt.timeIntervalSince($0) } ?? 0
        let startedAt = recordingStartTime ?? endedAt.addingTimeInterval(-duration)
        recordingStartTime = nil

        let capture = audioCaptureService.stopCapture()
        systemMicMute.reapplyReleasedMute()
        let samples = capture.samples
        let languageOverride = activeRecordingLanguageOverride
        activeRecordingLanguageOverride = nil
        let inputUID = activeRecordingInputUID
        activeRecordingInputUID = nil
        // Taken here so every early return below can drop it.
        let systemRecorder = systemAudioRecorder
        systemAudioRecorder = nil

        guard duration >= appState.minimumRecordingDuration else {
            logger.info("Recording too short (\(String(format: "%.1f", duration), privacy: .public)s), discarding")
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .idle
            activeRecordingPresetID = nil
            if let systemRecorder { Task { _ = await systemRecorder.stop() } }
            return
        }

        // The engine ran for a full dictation without a single input buffer:
        // that's the coreaudiod wedge, not silence. Name it instead of
        // transcribing nothing.
        if capture.health == .halStarved {
            logger.error("Dictation got zero buffers from the HAL — surfacing audio-wedge guidance")
            floatingPanel.hide()
            audioLevelMeter.reset()
            activeRecordingPresetID = nil
            if let systemRecorder { Task { _ = await systemRecorder.stop() } }
            appState.dictationState = .error(AudioCaptureService.halStarvedAdvice)
            return
        }

        logger.notice("Recording complete: \(String(format: "%.1f", duration), privacy: .public)s")
        // Leave .listening right away: stopping the system audio tap below
        // takes a moment, and a second stopDictation (or a new dictation)
        // must not slip in while it drains.
        appState.dictationState = .transcribing
        let presetID = activeRecordingPresetID
        Task {
            var systemSamples: [Float]?
            if let systemRecorder {
                systemSamples = await systemRecorder.stop()
                if systemSamples == nil {
                    logger.error("System audio tap did not stop within \(SystemAudioRecorder.stopTimeout, privacy: .public), saving the log with the mic only")
                    self.systemAudioUnavailable = true
                } else if systemSamples?.isEmpty == true {
                    logger.warning("System audio tap delivered no samples, saving the log with the mic only")
                    self.systemAudioUnavailable = true
                }
            }
            if let system = systemSamples, !system.isEmpty {
                let mic = (samples?.isEmpty == false) ? samples : nil
                if mic == nil {
                    logger.warning("Microphone delivered no samples, the log has system audio only")
                }
                await self.runLogWithSystemAudio(mic: mic, micStartedAt: capture.startedAt,
                                                 system: system, systemStartedAt: systemRecorder?.startedAt,
                                                 presetID: presetID, languageOverride: languageOverride,
                                                 startedAt: startedAt, endedAt: endedAt)
                return
            }
            await self.runPipeline(audioSeconds: duration, startedAt: startedAt, endedAt: endedAt,
                                   samples: samples, inputUID: inputUID) {
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

    /// A log preset with system audio: both tracks through the meeting
    /// pipeline ("Me" from the mic alone, "Other N" from the system track),
    /// then saved as a log with paragraphs. `mic` is nil when the mic gave
    /// nothing; the log then holds the system track only.
    private func runLogWithSystemAudio(mic rawMic: [Float]?, micStartedAt: Date?,
                                       system rawSystem: [Float], systemStartedAt: Date?,
                                       presetID: UUID?, languageOverride: String?,
                                       startedAt: Date, endedAt: Date) async {
        appState.dictationState = .transcribing
        // The tap starts a moment after the mic. Pad the later track so
        // paragraph times and the kept mix line up.
        var mic = rawMic
        var system = rawSystem
        if let rawMic {
            let aligned = AudioMix.alignStarts(rawMic, startedAt: micStartedAt, rawSystem, startedAt: systemStartedAt)
            mic = aligned.a
            system = aligned.b
            if let micStartedAt, let systemStartedAt {
                let offset = systemStartedAt.timeIntervalSince(micStartedAt)
                logger.info("Log tracks start offset: \(String(format: "%.3f", offset), privacy: .public)s (system after mic)")
            }
        }
        defer { activeRecordingPresetID = nil }
        let preset = appState.presets.first { $0.id == presetID } ?? appState.activePreset
        var llm: (any LLMService)?
        if preset.requiresAI {
            let service = appState.currentLLMService()
            if await service.isAvailable {
                llm = service
            } else {
                logger.warning("LLM provider not available, applying non-AI steps only")
            }
        }
        let pipeline = MeetingTranscriptionPipeline(engine: transcriptionEngine, diarization: diarizationService)
        do {
            let output = try await pipeline.run(
                mic: mic.map { .samples($0) } ?? .absent,
                system: .samples(system),
                config: .init(
                    diarizeMic: appState.meetingDiarizeMic,
                    diarizeSystem: appState.meetingDiarizeSystem,
                    languageOverride: languageOverride,
                    preset: llm == nil ? preset.withoutAI : preset,
                    llmService: llm
                )
            )
            let text = output.paragraphs.map(\.text).joined(separator: "\n\n")
            await saveLogEntry(text, preset: preset, startedAt: startedAt, endedAt: endedAt,
                               detectedLanguage: output.language, samples: mic,
                               paragraphs: output.paragraphs, systemSamples: system)
        } catch {
            logger.error("Log with system audio failed: \(error.localizedDescription, privacy: .public)")
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .error(error.localizedDescription)
        }
    }

    private func runPipeline(
        audioSeconds: Double,
        startedAt: Date,
        endedAt: Date,
        samples: [Float]?,
        inputUID: String?,
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
                let uid = inputUID ?? "system default"
                let deviceResolved = inputUID.map { AudioDeviceLookup.deviceID(forUID: $0) != nil } ?? true
                logger.error("Empty transcription after \(String(format: "%.1f", audioSeconds), privacy: .public)s — input UID \(uid, privacy: .public) (still connected: \(deviceResolved, privacy: .public)). If this persists, check Privacy & Security > Microphone for Roger.")
                floatingPanel.hide()
                audioLevelMeter.reset()
                appState.dictationState = .error("No speech detected. Try speaking louder or closer to the mic.")
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
                        if activePreset.output == .logEntry {
                            // A file surprises nobody: save the non-AI text.
                            await saveLogEntry(safeText, preset: activePreset, startedAt: startedAt, endedAt: endedAt,
                                               detectedLanguage: result.detectedLanguage, samples: samples)
                            return
                        }
                        appState.lastTranscription = safeText
                        appState.lastLogEntryURL = nil
                        floatingPanel.hide()
                        audioLevelMeter.reset()
                        appState.dictationState = .error("AI declined this dictation. Copy the transcript from the menu bar.")
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

            if activePreset.output == .logEntry {
                await saveLogEntry(processedText, preset: activePreset, startedAt: startedAt, endedAt: endedAt,
                                   detectedLanguage: result.detectedLanguage, samples: samples)
                return
            }

            appState.dictationState = .inserting
            appState.lastTranscription = processedText
            appState.lastLogEntryURL = nil

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

    /// Any new panel session (dictation, file job, meeting) cancels the pending
    /// "Logged" state and its hide timer.
    private func cancelLogSavedIndicator() {
        showsLogSaved = false
        logSavedNote = nil
        logSavedGeneration += 1
    }

    /// Writes a log entry instead of typing (`LogEntrySaver`). On failure
    /// the text stays in `lastTranscription` so nothing is lost.
    private func saveLogEntry(
        _ text: String,
        preset: DictationPreset,
        startedAt: Date,
        endedAt: Date,
        detectedLanguage: String?,
        samples: [Float]?,
        paragraphs: [MeetingTranscriptMerger.Paragraph]? = nil,
        systemSamples: [Float]? = nil
    ) async {
        let layout = appState.libraryLayout
        // The menu bar shows the new text while a long recording is encoded.
        if !LogEntrySaver.isEmpty(text) { appState.lastTranscription = text }
        let outcome = await LogEntrySaver(layout: layout).save(
            text, preset: preset, startedAt: startedAt, endedAt: endedAt,
            detectedLanguage: detectedLanguage, samples: samples,
            paragraphs: paragraphs, systemSamples: systemSamples
        ) { [libraryChanges] url in
            libraryChanges.recordWritten(markdownURL: url, kind: .log, root: layout.root)
        }
        switch outcome {
        case .empty:
            logger.info("Log entry skipped: empty text after processing")
            appState.lastLogEntryURL = nil
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .error("No speech detected - try speaking louder or closer to the mic")
            return
        case .saved(let url):
            appState.lastTranscription = text
            appState.lastLogEntryURL = url
            logger.notice("Log entry saved: \(url.path, privacy: .public)")
            Task { await self.runCommand(preset.commandID, markdownURL: url, kind: .log, root: layout.root) }
        case .libraryMissing(let message):
            logger.error("Log entry write failed: \(message, privacy: .public)")
            appState.lastTranscription = text
            appState.lastLogEntryURL = nil
            floatingPanel.hide()
            audioLevelMeter.reset()
            // The text must not be lost: it goes to the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            appState.dictationState = .error("\(message) The text is on the clipboard.")
            return
        case .failed(let message):
            logger.error("Log entry write failed: \(message, privacy: .public)")
            appState.lastTranscription = text
            appState.lastLogEntryURL = nil
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .error("Could not save the log entry. Copy the text from the menu bar.")
            return
        }

        audioLevelMeter.reset()
        appState.dictationState = .idle
        logSavedGeneration += 1
        let generation = logSavedGeneration
        logSavedNote = systemAudioUnavailable ? "system audio unavailable" : nil
        systemAudioUnavailable = false
        showsLogSaved = true
        // Detached from the pipeline so `runPipeline` returns right away and a
        // new dictation is not held up (its defer clears the active preset).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard generation == self.logSavedGeneration else { return }
            self.showsLogSaved = false
            self.logSavedNote = nil
            // A new dictation may have started meanwhile; it owns the panel then.
            if self.appState.dictationState == .idle {
                self.floatingPanel.hide()
            }
        }
    }

    /// Returns a copy of `preset` with every AI step disabled — used when the
    /// configured LLM provider is unavailable or refuses to process the text.
    private static func nonAIFallback(from preset: DictationPreset) -> DictationPreset {
        preset.withoutAI
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
            if let pending = pendingMediaFile {
                pendingMediaFile = nil
                handleDroppedMediaFile(url: pending)
            }
        } catch {
            logger.error("Model setup failed: \(error)")
            isSettingUpModel = false
            modelSetupProgress = nil
            lastModelError = error.localizedDescription
            pendingMediaFile = nil
            appState.dictationState = .error("Model download failed. Check your connection and retry.")
        }
    }

    // MARK: - Microphone Warm-Up

    /// Relaunches the app — the fix for a process-scoped CoreAudio wedge.
    /// Refuses while a meeting recording is active so a live session never
    /// has to go through crash recovery.
    func relaunchApp() {
        guard !meetingRecorder.isActive else {
            appState.dictationState = .error("Stop the meeting recording before relaunching Roger")
            return
        }
        logger.notice("Relaunching Roger on user request (audio-wedge recovery)")
        AppRelauncher.relaunch()
    }

    /// Fires a brief silent capture so the CoreAudio HAL is warm before the
    /// user's first real Caps Lock press. Safe to call repeatedly - re-entrant
    /// calls are coalesced. Never runs during a meeting: a second engine next
    /// to the meeting's mic tap can switch a Bluetooth headset's profile.
    func warmUpMicrophone() async {
        guard permissionManager.microphoneAuthorized else { return }
        guard !isWarmingUp else { return }
        guard appState.dictationState == .idle, !meetingRecorder.isActive else { return }
        isWarmingUp = true
        defer { isWarmingUp = false }
        let resolved = appState.resolvedInputDeviceUID
        let device = AudioDeviceLookup.actualInputUID(resolved: resolved)
        if await audioCaptureService.warmUp(inputUID: resolved) {
            warmUpTracker.didWarmUp(device: device)
        }
    }

    /// Warms the microphone up again when a device connects or disconnects and
    /// the priority list now resolves to another one. Lives for the app lifetime.
    func startInputDeviceMonitoring() {
        guard inputDeviceMonitor == nil else { return }
        let monitor = InputDeviceMonitor { [weak self] in
            guard let self else { return }
            self.inputDevicesGeneration += 1
            let device = AudioDeviceLookup.actualInputUID(resolved: self.appState.resolvedInputDeviceUID)
            guard self.warmUpTracker.shouldWarmUp(device: device) else { return }
            logger.info("Input devices changed, Roger now uses \(device ?? "no device", privacy: .public)")
            Task { await self.warmUpMicrophone() }
        }
        inputDeviceMonitor = monitor
        monitor.start()
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
            if lastModelError == nil {
                logger.info("Speech model still loading — queued: \(url.lastPathComponent, privacy: .public)")
                pendingMediaFile = url
            } else {
                appState.dictationState = .error("Speech model not ready. Download it in Settings > Speech Model.")
            }
            return
        }

        // Clear any prior error so the user sees the transcription overlay.
        if case .error = appState.dictationState {
            appState.dictationState = .idle
        }

        let job = FileTranscriptionJob(sourceURL: url, displayName: url.lastPathComponent)
        activeFileTranscription = job
        floatingPanel.show(coordinator: self)
        cancelLogSavedIndicator()

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

            let recording = await MediaAudioExtractor.recordingInfo(for: job.sourceURL)
            try Task.checkCancellation()

            // Diarized jobs end up as timestamped speaker paragraphs; the
            // plain path as one block of text. Each piece is cleaned up on
            // its own so filler removal never touches the speaker headers.
            var paragraphs: [MeetingTranscriptMerger.Paragraph] = []
            var plainText = ""
            var detectedLanguage: String?
            var diarized = false
            var diarizationFailed = false

            if appState.fileTranscriptionDiarize {
                let detailed = try await transcriptionEngine.transcribeFileDetailed(
                    url: prepared.url,
                    languageOverride: languageOverride
                )
                try Task.checkCancellation()
                detectedLanguage = detailed.result.detectedLanguage
                let languageName = Self.languageName(for: detectedLanguage)

                // Diarization is best-effort: if model download or inference fails,
                // fall back to the plain transcription rather than surfacing an error.
                fileTranscriptionDiarizing = true
                do {
                    let aligned = try await diarizationService.speakerSegments(
                        samples: detailed.audioSamples,
                        tokens: detailed.tokenTimings,
                        progress: { [weak self, job] fraction in
                            Task { @MainActor in
                                guard let self, self.fileTranscriptionDiarizing, self.activeFileTranscription == job else { return }
                                self.fileTranscriptionProgress = min(1, max(0, fraction))
                            }
                        }
                    )
                    fileTranscriptionDiarizing = false
                    fileTranscriptionProgress = nil
                    diarized = !aligned.isEmpty
                    // Number speakers by first appearance, not by cluster id.
                    var speakerNumbers: [String: Int] = [:]
                    for segment in Self.mergeSpeakerRuns(aligned) {
                        let text = try await postProcessor.process(
                            segment.text,
                            preset: preset,
                            language: languageName,
                            llmService: nil
                        )
                        guard !text.isEmpty else { continue }
                        if speakerNumbers[segment.speakerId] == nil {
                            speakerNumbers[segment.speakerId] = speakerNumbers.count + 1
                        }
                        paragraphs.append(.init(
                            speaker: "Speaker \(speakerNumbers[segment.speakerId]!)",
                            startTime: Float(segment.startTime),
                            text: text
                        ))
                    }
                } catch {
                    fileTranscriptionDiarizing = false
                    fileTranscriptionProgress = nil
                    diarizationFailed = true
                    logger.warning("Diarization failed, using plain transcript: \(error.localizedDescription, privacy: .public)")
                }
                if !diarized {
                    plainText = try await postProcessor.process(
                        detailed.result.text,
                        preset: preset,
                        language: languageName,
                        llmService: nil
                    )
                }
            } else {
                let r = try await transcriptionEngine.transcribeFile(
                    url: prepared.url,
                    languageOverride: languageOverride
                )
                try Task.checkCancellation()
                detectedLanguage = r.detectedLanguage
                plainText = try await postProcessor.process(
                    r.text,
                    preset: preset,
                    language: Self.languageName(for: detectedLanguage),
                    llmService: nil
                )
            }

            try Task.checkCancellation()

            guard !paragraphs.isEmpty || !plainText.isEmpty else {
                logger.warning("File transcription produced empty text: \(job.displayName, privacy: .public)")
                await finishFileTranscription(error: "No speech detected in \(job.displayName)")
                return
            }

            let layout = appState.libraryLayout
            let outputURL = try TranscriptOutputWriter.write(
                source: job.sourceURL,
                location: appState.fileTranscriptOutputLocation,
                layout: layout
            ) { destination in
                MediaTranscriptFormatter.content(
                    source: job.sourceURL,
                    destination: destination,
                    recording: recording,
                    paragraphs: paragraphs,
                    plainText: plainText,
                    language: detectedLanguage,
                    diarized: diarized,
                    diarizationFailed: diarizationFailed
                )
            }
            if appState.fileTranscriptOutputLocation == .alongsideSource {
                do {
                    try ExternalTranscriptRegistry.standard.add(outputURL)
                } catch {
                    logger.warning("Could not remember transcript path: \(error.localizedDescription, privacy: .public)")
                }
            }
            libraryChanges.recordWritten(markdownURL: outputURL, kind: .transcript, root: layout.root)
            logger.notice("File transcription saved: \(outputURL.path, privacy: .public)")
            Task { await self.runCommand(self.appState.fileTranscriptCommandID, markdownURL: outputURL, kind: .transcript, root: layout.root) }
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

    /// Joins consecutive segments of the same speaker into one paragraph.
    private static func mergeSpeakerRuns(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
        var merged: [SpeakerSegment] = []
        for segment in segments {
            if let last = merged.last, last.speakerId == segment.speakerId {
                merged[merged.count - 1] = SpeakerSegment(
                    speakerId: last.speakerId,
                    startTime: last.startTime,
                    endTime: segment.endTime,
                    text: last.text + " " + segment.text
                )
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func languageName(for code: String?) -> String {
        guard let code else { return "the original language" }
        return WhisperLanguage.displayName(for: code)
    }

    private func finishFileTranscription(error: String?) async {
        activeFileTranscription = nil
        fileTranscriptionProgress = nil
        fileTranscriptionDiarizing = false
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
        // `.error` from an earlier run is not active and must not block a
        // new recording.
        guard !meetingRecorder.isActive else {
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
            cancelLogSavedIndicator()
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
    /// library window will show the result.
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
        // Refresh recovery list: a freshly finalised session won't be in
        // it, but a failed one will.
        refreshPendingMeetingSessions()
    }

    /// Toggle visibility of the floating overlay during active capture. No-op
    /// outside of the recording phase so it can't accidentally hide the
    /// finalising / error overlay.
    func setMeetingOverlayHidden(_ hidden: Bool) {
        guard case .recording = meetingRecorder.state else { return }
        meetingOverlayHidden = hidden
        floatingPanel.setMeetingOverlayHidden(hidden)
    }

    /// A screenshot was dropped on the floating overlay during a meeting
    /// recording — record it as a checkpoint.
    func handleMeetingCheckpointDrop(_ image: MeetingCheckpointImage, droppedAt: Date) {
        meetingRecorder.addCheckpoint(image: image, droppedAt: droppedAt)
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
        cancelLogSavedIndicator()
        await meetingRecorder.finaliseRecovered(session)
        floatingPanel.hide()
        // Errors from the pipeline (e.g. encode failed, model unavailable)
        // reach the menu bar through `observeRecorderState`.
        refreshPendingMeetingSessions()
    }

    /// Drops a recovered session from the pending list without finalising
    /// (the user opted to discard or handle it manually).
    /// The dismissal is stored by folder path and survives relaunch.
    func dismissPendingMeeting(_ session: MeetingSession) {
        let path = session.folder.standardizedFileURL.path
        if !appState.dismissedMeetingSessions.contains(path) {
            appState.dismissedMeetingSessions.append(path)
        }
        pendingMeetingSessions.removeAll { $0.id == session.id }
    }

    /// Also called by the library after it moved a meeting to the Trash, so
    /// the popover banner and the Unfinished list drop it right away. Only
    /// Roger's own session folders are offered (see `LibraryActions.finalisable`).
    func refreshPendingMeetingSessions() {
        pendingMeetingSessions = LibraryActions.finalisable(
            meetingRecorder.unfinalisedSessions(),
            layout: appState.libraryLayout,
            extraFolders: appState.extraScanFolders,
            dismissed: Set(appState.dismissedMeetingSessions)
        )
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

/// The login shell's `PATH` plus the extra folders, looked up once per
/// launch for the commands (the shell takes a moment to answer).
@MainActor
private final class CommandSearchPathCache {
    private var cached: [String]?

    func value(runner: any CommandRunner, home: URL) async -> [String] {
        if let cached { return cached }
        let shellPATH = await CLILocator.loginShellPATH(runner: runner, home: home)
        let path = CLILocator.searchPath(loginShellPATH: shellPATH, home: home)
        // A shell that did not answer is asked again on the next run.
        if shellPATH != nil { cached = path }
        return path
    }
}
