# Dependency-Unlocked Features: Progress UI and Hotkey Validation

**Date:** 2026-07-23
**Status:** Approved
**Context:** FluidAudio 0.15.2 → 0.15.5 and KeyboardShortcuts 2.4.0 → 3.0.1 (already committed in `a4a56d4`) unlocked new APIs. This spec covers the three features adopting them.

## Scope

Three features, one implementation cycle:

1. Determinate model download progress (Onboarding, Settings, menu bar)
2. Real diarization progress (meeting finalisation, file transcription overlay)
3. Meeting-hotkey validation (system-shortcut warning, F18 block)

**Explicitly deferred:** adopting the Parakeet Unified 0.6B streaming backend. It is English-only (fixed `nvidia/parakeet-unified-en-0.6b` repo, no language parameter, 1024-token English vocab) and would add a second ~500 MB model whose only near-term payoff is a live dictation preview that renders German speech as wrong English-ish text until the final TDT v3 pass replaces it. The Base Station/Handheld brainstorm will pick the streaming backend (English-only Unified vs the multilingual Nemotron family) with full information.

## Feature 1: Model download progress

### Problem

`AppCoordinator.setupModel()` discards the progress handler (`transcriptionEngine.setup { _ in }`). All three loading spots show indeterminate spinners: `OnboardingView` model step, `SettingsView` Speech Model card and the `MenuBarView` "Loading model…" row.

### FluidAudio API

`AsrModels.downloadAndLoad(..., progressHandler: ProgressHandler?)` where

```swift
public typealias ProgressHandler = @Sendable (DownloadProgress) -> Void

public struct DownloadProgress: Sendable {
    public let fractionCompleted: Double   // 0...1, byte-weighted internally
    public let phase: DownloadPhase
}

public enum DownloadPhase: Sendable {
    case listing
    case downloading(completedFiles: Int, totalFiles: Int)
    case compiling(modelName: String)
}
```

There is no public bytes-downloaded/total-bytes API - the finest public granularity is the byte-weighted fraction plus per-file counts. For repo loads the download phase spans fraction 0.0-0.5 and CoreML compilation 0.5-1.0, so one continuous bar covers both. The handler is called on an unspecified queue.

### Design

- **TranscriptionEngine** maps `DownloadProgress` to a Roger-owned value so FluidAudio types stay out of the coordinator and UI (same containment discipline as `DiarizationService`):

  ```swift
  struct ModelSetupProgress: Sendable, Equatable {
      let fraction: Double       // 0...1
      let stage: String          // user-facing label
  }
  ```

  `setup(progressHandler:)` changes its parameter from `(Double) -> Void` to `(ModelSetupProgress) -> Void`. Stage mapping:
  - `.listing` → "Preparing download…"
  - `.downloading(c, t)` → "Downloading model - file c of t"
  - `.compiling` → "Optimizing for Neural Engine…"

- **AppCoordinator** gains observable state `modelSetupProgress: ModelSetupProgress?` - non-nil exactly while `isSettingUpModel` is true, cleared in both the success and failure paths of `setupModel()`. Handler updates hop to the main actor.

- **UI**: all three spots replace the indeterminate spinner with `ProgressView(value:)` plus the stage text and a percentage. Layout stays otherwise unchanged; when `modelSetupProgress` is nil but `isSettingUpModel` is true (a brief startup window before the first callback), fall back to today's indeterminate spinner.

Cached launches (model already on disk) still report `.compiling`/load phases quickly; the determinate bar simply fills fast. No behavioral change on the error path.

### Rejected alternative

Passing FluidAudio's `DownloadProgress` to the views directly - leaks dependency types into the UI layer, which the codebase deliberately avoids.

## Feature 2: Diarization progress

### Problem

- `MeetingRecordingService.runFinalisationPipeline` fakes progress with hand-tuned milestones (0.05, 0.15, 0.30, 0.45, 0.65, 0.85). The bar sits still during the longest stages.
- The file transcription overlay (`FloatingPanel`) shows only "Transcribing" plus the filename - no progress at all.

### FluidAudio API

```swift
public func performCompleteDiarization<C>(
    _ samples: C, sampleRate: Int = 16000, atTime startTime: TimeInterval = 0,
    progressHandler: ((Double) -> Void)? = nil
) throws -> DiarizationResult
```

Plain 0...1 fraction, one callback per processed chunk (roughly every 10 s of audio - no throttling needed), called synchronously on the calling thread, final call reports 1.0.

### Design

- **DiarizationService**: `diarize` and `speakerSegments` gain `progress: (@Sendable (Double) -> Void)? = nil`, forwarded to `performCompleteDiarization(progressHandler:)`. Callbacks fire inside the actor; consumers hop to the main actor before touching observable state.

- **Meeting finalisation**: milestones stay for stages without callbacks (encode, ASR). Diarization fills its window continuously:
  - mic ASR done → 0.55, mic diarization fills 0.55 → 0.65
  - system ASR done → 0.75, system diarization fills 0.75 → 0.85

  The `finalising(progress:)` state and the "Encoding & transcribing - X%" label in `MenuBarView` are unchanged. When diarization is disabled for a track, the pipeline jumps straight to the next milestone exactly as today.

- **File transcription overlay**: `AppCoordinator` gains observable `fileTranscriptionProgress: Double?` - nil during ASR (indeterminate, today's behavior), set during the diarization phase, cleared when the job ends (success, failure or cancel). While non-nil, the overlay's subtitle line shows "Identifying speakers - X%" instead of the filename, then the flow completes as today. Only applies when `fileTranscriptionDiarize` is on; the non-diarized path is untouched.

Error behavior is unchanged everywhere - the progress parameter is optional and diarization failures keep their existing fallbacks.

### Rejected alternative

An `AsyncStream`/observable progress publisher on the DiarizationService actor - more machinery, and the service would need to know about UI progress windows that belong to its callers.

## Feature 3: Meeting-hotkey validation

### Problem

The meeting-recording toggle (the only shortcut using `KeyboardShortcuts.Recorder`; dictation uses F18 via CGEvent tap) accepts any shortcut, including ones the system owns and F18 itself - which would collide with Roger's own dictation hotkey.

### KeyboardShortcuts 3.0 API

- Built-in `ConflictPolicy` (default: `systemShortcut: .warn`, `menuItem: .block`, `disallowed: .block`) - the Recorder now warns about system-owned shortcuts out of the box. No code needed, verification only.
- `Recorder.shortcutValidation((Shortcut) -> ValidationResult)` with `.allow` / `.disallow(reason:)` for app-specific rules.
- `Shortcut.isTakenBySystem` exists for custom UIs - not needed here.

### Design

Add one Roger-specific rule in `RecordingsSettingsView`:

```swift
KeyboardShortcuts.Recorder(for: .meetingRecordingToggle)
    .shortcutValidation { shortcut in
        if shortcut.key == .f18 {
            return .disallow(reason: "F18 is Roger's dictation hotkey (Caps Lock).")
        }
        return .allow
    }
```

The built-in policy handles system conflicts; no custom `ConflictPolicy` override.

## Verification

No test target exists, so: clean Debug build, then manual runtime checks -

1. Settings > Model > Uninstall, re-download: determinate bar with stage text in Settings, menu bar and Onboarding (via a fresh-defaults launch or the Settings card alone).
2. Drop a multi-speaker audio file with diarization enabled: subtitle switches to "Identifying speakers - X%" during diarization; cancel mid-way still cleans up.
3. Record a short meeting with diarization on: finalisation bar moves continuously through the diarization windows.
4. In Recordings settings, try assigning Cmd+Space (system warning appears) and F18 (blocked with the dictation-hotkey reason).
