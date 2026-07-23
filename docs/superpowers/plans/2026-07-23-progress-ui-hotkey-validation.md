# Progress UI and Hotkey Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt the FluidAudio 0.15.5 and KeyboardShortcuts 3.0.1 APIs for determinate model download progress, real diarization progress and meeting-hotkey validation, per `docs/superpowers/specs/2026-07-23-dependency-features-design.md`.

**Architecture:** Progress flows service → coordinator → view. `TranscriptionEngine` maps FluidAudio's `DownloadProgress` into a Roger-owned `ModelSetupProgress`; `DiarizationService` forwards a plain 0-1 fraction. `AppCoordinator` (and `MeetingRecordingService.state`) hold observable progress state on the main actor; views render determinate `ProgressView(value:)` where they showed indeterminate spinners.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, FluidAudio 0.15.5, KeyboardShortcuts 3.0.1.

## Global Constraints

- macOS 14.4 deployment target, Swift 6 strict concurrency; `@MainActor` for all `@Observable` types SwiftUI observes.
- FluidAudio types must not leak into coordinators or views (`ModelSetupProgress` and plain `Double` fractions are the boundary types).
- **No new files.** All changes go into existing files, so `xcodegen generate` is never needed (regenerating clobbers `Resources/Roger.entitlements`).
- **No test target exists.** Each task's verification cycle is a Debug build; runtime verification is the final task's manual checklist. Build command (from `Roger/`): `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`. Never pass `CONFIGURATION_BUILD_DIR` to Debug builds.
- User-facing strings: no Oxford comma; use "-", never "—".
- Commits: plain conventional-commit messages. No AI attribution of any kind (no Co-Authored-By trailers, no "Generated with" lines).
- Progress callbacks from FluidAudio arrive on unspecified queues/threads - always hop to the main actor before touching observable state.

**Subagent model tiers:** Task 1 sonnet, Task 2 haiku, Task 3 haiku, Task 4 sonnet, Task 5 sonnet, Task 6 haiku, Task 7 main session.

---

### Task 1: ModelSetupProgress in TranscriptionEngine + AppCoordinator state

**Model tier:** sonnet

**Files:**
- Modify: `Roger/Services/TranscriptionEngine.swift` (the `setup` method, ~line 39, plus a new top-level struct)
- Modify: `Roger/App/AppCoordinator.swift` (`setupModel`, ~line 403, plus one new observable property)

**Interfaces:**
- Consumes: FluidAudio's `DownloadProgress { fractionCompleted: Double, phase: DownloadPhase }` where `DownloadPhase` is `.listing`, `.downloading(completedFiles: Int, totalFiles: Int)` or `.compiling(modelName: String)`.
- Produces: top-level `struct ModelSetupProgress: Sendable, Equatable { let fraction: Double; let stage: String }` in `TranscriptionEngine.swift`; `TranscriptionEngine.setup(progressHandler: @Sendable @escaping (ModelSetupProgress) -> Void)`; `AppCoordinator.modelSetupProgress: ModelSetupProgress?` (observable, non-nil only while `isSettingUpModel`). Task 2 renders these.

- [ ] **Step 1: Add the struct and rewrite `setup` in `TranscriptionEngine.swift`**

Add above `final class TranscriptionEngine`:

```swift
/// User-facing snapshot of model download/compile progress. Mapped from
/// FluidAudio's `DownloadProgress` here so coordinators and views never
/// see FluidAudio types.
struct ModelSetupProgress: Sendable, Equatable {
    let fraction: Double
    let stage: String
}
```

Replace the existing `setup` method with:

```swift
/// Downloads (first launch) and loads Parakeet TDT v3 — the single
/// multilingual model Roger uses. `melChunkContext: false` is the
/// v3-recommended setting for multilingual long-form audio (avoids an
/// English-bias drift at chunk boundaries on e.g. German meeting audio).
func setup(progressHandler: @Sendable @escaping (ModelSetupProgress) -> Void) async throws {
    guard asrManager == nil else { return }
    let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
        progressHandler(ModelSetupProgress(
            fraction: progress.fractionCompleted,
            stage: Self.stageDescription(for: progress.phase)
        ))
    }
    asrManager = AsrManager(config: ASRConfig(melChunkContext: false), models: models)
    progressHandler(ModelSetupProgress(fraction: 1.0, stage: "Ready"))
    logger.info("Parakeet TDT v3 ready")
}

/// FluidAudio's fraction already spans download (0-0.5) and CoreML
/// compilation (0.5-1.0), so the stage label is the only mapping needed.
private static func stageDescription(for phase: DownloadPhase) -> String {
    switch phase {
    case .listing:
        return "Preparing download…"
    case .downloading(let completed, let total):
        return "Downloading model - file \(min(completed + 1, max(total, 1))) of \(total)"
    case .compiling:
        return "Optimizing for Neural Engine…"
    }
}
```

- [ ] **Step 2: Add the observable property and wire it in `AppCoordinator.swift`**

Next to the existing `isSettingUpModel` property declaration, add:

```swift
/// Live download/compile progress while `isSettingUpModel` — nil outside
/// setup and before the first callback arrives (UI falls back to an
/// indeterminate spinner for that brief window).
var modelSetupProgress: ModelSetupProgress?
```

Replace the body of `setupModel()` so the handler feeds it and every exit clears it:

```swift
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
```

(The existing error string keeps its "—" - it predates the copy rule and changing it is out of scope.)

- [ ] **Step 3: Build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. The only other `setup` caller is `setupModel` itself; if the build surfaces another caller passing the old `(Double) -> Void` shape, update it the same way.

- [ ] **Step 4: Commit**

```bash
git add Roger/Services/TranscriptionEngine.swift Roger/App/AppCoordinator.swift
git commit -m "feat: surface model download progress from the transcription engine"
```

---

### Task 2: Determinate download progress in the three views

**Model tier:** haiku

**Files:**
- Modify: `Roger/UI/OnboardingView.swift` (`modelStep`, the `coordinator.isSettingUpModel` branch, ~line 204)
- Modify: `Roger/UI/SettingsView.swift` (Speech Model card, the `isSettingUp` branch, ~line 741)
- Modify: `Roger/UI/MenuBarView.swift` (the `coordinator.isSettingUpModel` block, ~line 27)

**Interfaces:**
- Consumes: `coordinator.modelSetupProgress: ModelSetupProgress?` (`.fraction: Double`, `.stage: String`) and `coordinator.isSettingUpModel: Bool` from Task 1.
- Produces: UI only, nothing downstream.

- [ ] **Step 1: OnboardingView**

Replace the `} else if coordinator.isSettingUpModel {` branch body with:

```swift
} else if coordinator.isSettingUpModel {
    VStack(spacing: 8) {
        if let progress = coordinator.modelSetupProgress {
            ProgressView(value: progress.fraction)
                .frame(width: 220)
            Text("\(progress.stage) (\(Int(progress.fraction * 100))%)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.regular)
            Text("Loading model…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: SettingsView Speech Model card**

Replace the `if isSettingUp {` branch body (currently a spinner + "Loading…" HStack) with:

```swift
if isSettingUp {
    VStack(alignment: .trailing, spacing: 4) {
        if let progress = coordinator.modelSetupProgress {
            ProgressView(value: progress.fraction)
                .frame(width: 140)
            Text(progress.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: MenuBarView**

Replace the `if coordinator.isSettingUpModel {` block with:

```swift
if coordinator.isSettingUpModel {
    VStack(alignment: .leading, spacing: 4) {
        if let progress = coordinator.modelSetupProgress {
            ProgressView(value: progress.fraction)
            Text("\(progress.stage) (\(Int(progress.fraction * 100))%)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
}
```

- [ ] **Step 4: Build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Roger/UI/OnboardingView.swift Roger/UI/SettingsView.swift Roger/UI/MenuBarView.swift
git commit -m "feat: determinate model download progress in onboarding, settings and menu bar"
```

---

### Task 3: Progress parameter on DiarizationService

**Model tier:** haiku

**Files:**
- Modify: `Roger/Services/Diarization/DiarizationService.swift` (both public methods)

**Interfaces:**
- Consumes: FluidAudio `performCompleteDiarization(_:sampleRate:atTime:progressHandler:)` where `progressHandler: ((Double) -> Void)?` reports 0-1 per chunk, synchronously on the calling thread, final call 1.0.
- Produces: `diarize(_ samples: [Float], progress: (@Sendable (Double) -> Void)? = nil)` and `speakerSegments(samples: [Float], tokens: [TokenTiming], progress: (@Sendable (Double) -> Void)? = nil)`. Tasks 4 and 5 pass `progress:`. Existing call sites compile unchanged (defaulted parameter).

- [ ] **Step 1: Add the parameter to both methods**

Replace the two methods with:

```swift
/// Clusters speakers over 16 kHz mono samples, returning time-ranged
/// speaker segments. Loads models on first use. `progress` reports a
/// 0-1 fraction roughly once per processed chunk, on the actor's thread.
func diarize(
    _ samples: [Float],
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> [TimedSpeakerSegment] {
    try await prepare()
    return try manager.performCompleteDiarization(
        samples,
        sampleRate: 16000,
        progressHandler: progress
    ).segments
}

/// Diarizes `samples` and aligns the result against ASR `tokens`, returning
/// Roger's speaker-attributed segments. Keeps FluidAudio's `TokenTiming` /
/// `TimedSpeakerSegment` types out of the calling coordinators.
func speakerSegments(
    samples: [Float],
    tokens: [TokenTiming],
    progress: (@Sendable (Double) -> Void)? = nil
) async throws -> [SpeakerSegment] {
    let segments = try await diarize(samples, progress: progress)
    return SpeakerAligner.align(tokens: tokens, diarization: segments)
}
```

- [ ] **Step 2: Build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`
Expected: `** BUILD SUCCEEDED **` (existing callers use the default nil).

- [ ] **Step 3: Commit**

```bash
git add Roger/Services/Diarization/DiarizationService.swift
git commit -m "feat: optional progress callback on diarization"
```

---

### Task 4: Real diarization progress in meeting finalisation

**Model tier:** sonnet

**Files:**
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (`runFinalisationPipeline`, mic block ~line 344 and system block ~line 377)

**Interfaces:**
- Consumes: `speakerSegments(samples:tokens:progress:)` from Task 3; the service's existing `state = .finalising(progress:)` milestones.
- Produces: behavior only - the finalisation bar fills 0.55→0.65 (mic diarization) and 0.75→0.85 (system diarization). No API changes.

- [ ] **Step 1: Add the monotonic progress helper**

The service is `@MainActor @Observable` (line 14-16), so plain `state` writes already happen on the main actor, but diarization progress callbacks arrive on the diarization actor's thread and hop over asynchronously - a late callback could land after the pipeline already set a higher milestone and briefly rewind the bar. Add this helper to `MeetingRecordingService` (near `runFinalisationPipeline`) so progress can only rise:

```swift
/// Raises finalisation progress, never lowers it — late async progress
/// callbacks must not rewind the bar past a milestone already set.
private func bumpFinalisingProgress(to value: Double) {
    if case .finalising(let current) = state, value > current {
        state = .finalising(progress: value)
    }
}
```

- [ ] **Step 2: Mic block - add the 0.55 milestone and progress mapping**

In the `if micPresent {` block, after `micLanguage = detailed.result.detectedLanguage`, insert:

```swift
state = .finalising(progress: 0.55)
```

Then extend the diarization call with the progress argument, hopping to the main actor and bumping monotonically:

```swift
let segments = try await diarization.speakerSegments(
    samples: detailed.audioSamples,
    tokens: detailed.tokenTimings,
    progress: { [weak self] fraction in
        Task { @MainActor in
            self?.bumpFinalisingProgress(to: 0.55 + fraction * 0.10)
        }
    }
)
```

- [ ] **Step 3: System block - add the 0.75 milestone and progress mapping**

Same shape in the `if systemPresent {` block: after `systemLanguage = detailed.result.detectedLanguage`, insert `state = .finalising(progress: 0.75)`, and extend its `speakerSegments` call:

```swift
systemSpeakerSegments = try await diarization.speakerSegments(
    samples: detailed.audioSamples,
    tokens: detailed.tokenTimings,
    progress: { [weak self] fraction in
        Task { @MainActor in
            self?.bumpFinalisingProgress(to: 0.75 + fraction * 0.10)
        }
    }
)
```

The pre-existing `state = .finalising(progress: 0.65)` (before the system block) and `state = .finalising(progress: 0.85)` (after it) stay exactly where they are - they are the fallbacks when diarization is disabled or fails. The plain milestone assignments (`0.55`, `0.65`, `0.75`, `0.85`) remain direct `state =` writes - the pipeline itself orders them; only the async callback path goes through `bumpFinalisingProgress`.

- [ ] **Step 4: Build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Roger/Services/MeetingRecording/MeetingRecordingService.swift
git commit -m "feat: real diarization progress in meeting finalisation"
```

---

### Task 5: Speaker-identification progress in the file transcription overlay

**Model tier:** sonnet

**Files:**
- Modify: `Roger/App/AppCoordinator.swift` (property near `activeFileTranscription`; `runFileTranscription`, diarize branch ~line 545; job cleanup where `activeFileTranscription` is reset)
- Modify: `Roger/UI/FloatingPanel.swift` (file-job subtitle, ~line 141)

**Interfaces:**
- Consumes: `speakerSegments(samples:tokens:progress:)` from Task 3.
- Produces: `AppCoordinator.fileTranscriptionProgress: Double?` (observable; non-nil only during a file job's diarization phase). FloatingPanel renders it.

- [ ] **Step 1: Add the observable property**

Next to `activeFileTranscription` in `AppCoordinator`, add:

```swift
/// 0-1 fraction while a file transcription job is in its speaker
/// identification phase; nil during ASR and outside file jobs. Drives
/// the overlay's "Identifying speakers" line.
var fileTranscriptionProgress: Double?
```

- [ ] **Step 2: Feed and clear it in `runFileTranscription`**

In the `appState.fileTranscriptionDiarize` branch, extend the `speakerSegments` call and clear the value on both exits of the do/catch:

```swift
let textToParse: String
do {
    let aligned = try await diarizationService.speakerSegments(
        samples: detailed.audioSamples,
        tokens: detailed.tokenTimings,
        progress: { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.activeFileTranscription != nil else { return }
                self.fileTranscriptionProgress = fraction
            }
        }
    )
    fileTranscriptionProgress = nil
    let diarized = formatDiarized(aligned)
    textToParse = diarized.isEmpty ? detailed.result.text : diarized
} catch {
    fileTranscriptionProgress = nil
    logger.warning("Diarization failed, using plain transcript: \(error.localizedDescription, privacy: .public)")
    textToParse = detailed.result.text
}
```

Also set `fileTranscriptionProgress = nil` at every place the job itself ends - wherever `activeFileTranscription` is set back to nil (success, error and cancellation paths; find each assignment and add the clear beside it). The `activeFileTranscription != nil` guard in the callback keeps a late in-flight callback from resurrecting the value after cleanup.

- [ ] **Step 3: FloatingPanel subtitle**

In the `if let job = fileJob {` block, replace the filename `Text` with:

```swift
if let fraction = coordinator.fileTranscriptionProgress {
    Text("Identifying speakers - \(Int(fraction * 100))%")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: 220, alignment: .leading)
} else {
    Text(job.displayName)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 220, alignment: .leading)
}
```

- [ ] **Step 4: Build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Roger/App/AppCoordinator.swift Roger/UI/FloatingPanel.swift
git commit -m "feat: speaker-identification progress in the file transcription overlay"
```

---

### Task 6: Block F18 on the meeting recording recorder

**Model tier:** haiku

**Files:**
- Modify: `Roger/UI/RecordingsSettingsView.swift` (~line 69)

**Interfaces:**
- Consumes: KeyboardShortcuts 3.0 `Recorder.shortcutValidation((Shortcut) -> ValidationResult)`, `Shortcut.key: Key?`, `Key.f18`, `ValidationResult.allow` / `.disallow(reason:)`. The built-in default `ConflictPolicy` already warns on system-owned shortcuts - no code for that.
- Produces: UI only.

- [ ] **Step 1: Add the validation modifier**

Replace `KeyboardShortcuts.Recorder(for: .meetingRecordingToggle)` with:

```swift
KeyboardShortcuts.Recorder(for: .meetingRecordingToggle)
    .shortcutValidation { shortcut in
        if shortcut.key == .f18 {
            return .disallow(reason: "F18 is Roger's dictation hotkey (Caps Lock).")
        }
        return .allow
    }
```

- [ ] **Step 2: Build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Roger/UI/RecordingsSettingsView.swift
git commit -m "feat: block F18 for the meeting recording hotkey"
```

---

### Task 7: Final verification (main session)

**Model tier:** main session (no subagent)

**Files:** none (verification only)

- [ ] **Step 1: Clean build**

Run from `Roger/`: `xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug clean build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Manual runtime checklist (hand to Jordi)**

1. Settings > Model > Uninstall, then re-download: determinate bar with stage text in the Settings card, menu bar row and (fresh-defaults launch) Onboarding step.
2. Drop a multi-speaker audio file with diarization enabled on the menu bar icon: subtitle switches to "Identifying speakers - X%" during diarization, cancel mid-way cleans up (no stuck overlay, no lingering progress).
3. Record a short meeting with diarization on: the finalisation bar moves continuously through the 0.55-0.65 and 0.75-0.85 windows instead of sitting still.
4. In Recordings settings: recording Cmd+Space shows the library's system-shortcut warning; recording F18 is blocked with the dictation-hotkey reason.
