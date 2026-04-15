# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Roger is a macOS menu bar Speech-to-Text app that enables dictation into any application. It captures audio via a global hotkey, transcribes using WhisperKit (on-device, Apple Silicon optimized), post-processes with AI, and inserts text at the cursor position.

**Key principles:** Privacy-first (local processing default), low latency, open source (MIT).

## Build & Run

```bash
# Generate Xcode project (after modifying project.yml)
cd Roger && xcodegen generate

# Build (Debug)
cd Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build

# Build (Release, for distribution)
cd Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Release build CONFIGURATION_BUILD_DIR=../build

# Build from repo root (same as AhPushIt/GitCanary pattern)
xcodebuild -project Roger/Roger.xcodeproj -scheme Roger -configuration Release build CONFIGURATION_BUILD_DIR=build
```

**Important:** Do NOT pass `CONFIGURATION_BUILD_DIR` during Debug builds — it breaks SPM package framework resolution. Only use it for Release/distribution builds.

After xcodegen regenerates the project, it clobbers `Resources/Roger.entitlements` to an empty dict. Restore the audio-input entitlement manually if this happens.

## Architecture

### Dictation Pipeline

```
HotkeyManager → AudioCaptureService → TranscriptionEngine → PostProcessor → TextInsertionService
```

All services are coordinated by `AppCoordinator` (@MainActor, @Observable).

### Key Services

- **HotkeyManager** — CGEvent tap listening for F18 (Caps Lock remapped via `hidutil`). Supports push-to-talk and toggle modes. Includes static methods for Caps Lock remap and LaunchAgent installation.
- **AudioCaptureService** — AVAudioEngine with installTap, converts to 16kHz mono float32 for WhisperKit.
- **TranscriptionEngine** — WhisperKit wrapper. Downloads model on first launch. Supports EN + DE.
- **PostProcessor** — Sequential pipeline: filler word removal → repeated word dedup → AI formatting → custom dictionary → optional rewrite. Driven by the active `DictationPreset`.
- **TextInsertionService** — Tries AXUIElement (Accessibility API) first, falls back to clipboard + simulated Cmd+V. AX insertion silently fails in Electron/web apps; the fallback detects this by comparing values before/after.
- **PermissionManager** — Checks and requests Microphone and Accessibility permissions.
- **KeychainManager** — Secure storage for LLM API keys (same pattern as GitCanary).

### LLM Provider Abstraction

Same pattern as GitCanary (`LLM/` directory):
- **LLMService** protocol with `processText(_ text: String, prompt: String) async throws -> String`
- Four providers: AppleIntelligenceService (macOS 26+, FoundationModels), OllamaService (local HTTP), ClaudeService (Anthropic API), OpenAIService
- Provider selection and config persisted in AppState via UserDefaults
- API keys stored in Keychain via KeychainManager
- Factory method: `appState.currentLLMService()`

### Dictation Presets

Four built-in presets with deterministic UUIDs (in `DictationPreset.builtInPresets`):
- **Plain** — Filler removal + dedup only, no AI
- **Polished** — Full pipeline with punctuation/formatting
- **Professional** — Full pipeline + AI rewrite for email-ready prose
- **Code** — Developer-aware, preserves technical terms

Custom presets supported with configurable pipeline steps, prompts, and dictionary entries. Persisted as JSON in UserDefaults.

### UI Layer

- **RogerApp** — `@main`, uses `MenuBarExtra(.window)` with `LSUIElement=YES` (no Dock icon). Settings via `Settings` scene.
- **MenuBarView** — Status, language picker, preset picker, last transcription, settings/quit actions. Settings opened via `SettingsLink` with `simultaneousGesture` to activate the app and bring window to front (same pattern as GitCanary).
- **FloatingIndicator** — Visual listening indicator (waveform animation in capsule overlay).
- **SettingsView** — Tabs: General, Permissions, AI Provider, Presets, Model, About.

### Text Insertion Strategy

1. Get focused element via `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute`
2. Check role is `kAXTextFieldRole` or `kAXTextAreaRole`
3. Set `kAXSelectedTextAttribute` to insert at cursor
4. Verify by comparing `kAXValueAttribute` before/after (detects silent failures)
5. On failure: save clipboard → set text → simulate Cmd+V → restore clipboard (configurable)

### Minimum Recording Duration

Recordings shorter than `appState.minimumRecordingDuration` (default 1.5s) are silently discarded. This prevents accidental hotkey taps from triggering transcription, especially important since Caps Lock remap via hidutil bypasses macOS's built-in ~250ms accidental-press delay.

## Dependencies (SPM via xcodegen)

- **WhisperKit** (argmaxinc/WhisperKit) — On-device speech recognition, CoreML/Neural Engine
- **KeyboardShortcuts** (sindresorhus/KeyboardShortcuts) — User-customizable global hotkeys

## Project Structure

```
Roger/
├── project.yml          # xcodegen spec (source of truth for .xcodeproj)
├── Roger.xcodeproj/     # Generated — do not edit manually
├── App/                 # Entry point, coordinator, state
├── UI/                  # SwiftUI views
├── Services/            # Business logic services
├── Models/              # Data models (presets, provider types, errors)
├── LLM/                 # LLM provider abstraction (protocol + implementations)
└── Resources/           # Info.plist, entitlements, assets
```

## Planned Features (not yet implemented)

- **Base Station / Handheld mode** — One Roger instance hosts transcription on LAN (Bonjour `_roger._tcp`), others connect as thin clients via WebSocket streaming.
- **Caps Lock setup assistant** — Guided onboarding for hidutil remap + LaunchAgent persistence.
- **Distribution** — Homebrew cask (`brew tap jordiboehme/tap`), GitHub Releases (DMG), GitHub Actions CI/CD.

## Conventions

- macOS 14.0+ deployment target, Swift 6 strict concurrency
- Bundle ID: `com.jordiboehme.roger`
- @MainActor for all @Observable types that SwiftUI observes
- `@unchecked Sendable` for service classes that manage their own thread safety (e.g., TranscriptionEngine with internal WhisperKit state)
- Logging via `os.Logger` with subsystem `com.jordiboehme.roger`
- Settings opened via `SettingsLink` + `simultaneousGesture` (not `openWindow` or selectors)
- Author name: "Jordi Böhme" (with umlaut)
