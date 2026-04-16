# Roger

A macOS menu bar app for speech-to-text dictation into any application. Press a hotkey, speak, and your words appear at the cursor — powered by on-device AI.

**Your voice stays on your machine.** Roger is local-first — speech recognition runs entirely on your Mac using the Neural Engine. Cloud AI providers are available for text cleanup but opt-in.

## Features

- **Dictate anywhere** — Text appears at the cursor in any app (Notes, Warp, VS Code, browsers)
- **On-device transcription** — WhisperKit with CoreML, no cloud required
- **Multilingual** — English and German with automatic language detection
- **AI post-processing** — Filler word removal, punctuation, grammar cleanup via configurable presets
- **Configurable presets** — Plain, Polished, Professional, Code, or create your own
- **Multiple AI providers** — Apple Intelligence, Ollama, Claude, OpenAI (same provider abstraction as [GitCanary](https://github.com/jordiboehme/GitCanary))
- **Push-to-talk or toggle** — Hold Caps Lock to record, or press once to start/stop
- **Visual feedback** — Floating indicator with orange glow while listening
- **Menu bar app** — Lives silently in your menu bar, no Dock icon

## Installation

### Homebrew (recommended)

```bash
brew tap jordiboehme/tap
brew install --cask roger
```

### Download

Grab the latest DMG from [GitHub Releases](https://github.com/jordiboehme/roger/releases), open it and drag Roger to Applications.

### Build from Source

```bash
git clone https://github.com/jordiboehme/roger.git
cd roger
xcodebuild -project Roger/Roger.xcodeproj -scheme Roger -configuration Release build CONFIGURATION_BUILD_DIR=build
```

Then move `build/Roger.app` to `/Applications` and launch it.

## Requirements

- **macOS 14 Sonoma** or later
- **Microphone permission** (prompted on first launch)
- **Accessibility permission** (required for text insertion and global hotkey)

## How It Works

Roger captures audio via `AVAudioEngine`, transcribes it on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (a CoreML implementation of [OpenAI Whisper](https://github.com/openai/whisper)), optionally post-processes the text with an AI provider, and inserts the result at your cursor using the Accessibility API (with a clipboard+paste fallback for Electron apps).

### Dictation Presets

| Preset | What it does |
|--------|-------------|
| **Plain** | Removes filler words and repeated words. No AI needed. |
| **Polished** | Adds punctuation, capitalization, and formatting via AI. |
| **Professional** | Full cleanup plus AI rewrite for clear, professional prose. |
| **Code** | Developer-aware — preserves technical terms and code references. |
| **Custom** | Your own pipeline steps, prompts, and dictionary. |

### AI Providers

| Provider | Type | Notes |
|----------|------|-------|
| **Apple Intelligence** | Local | On-device, macOS 26+, no setup required |
| **Ollama** | Local | Runs on your Mac or any machine on your network |
| **Claude** | Cloud | Anthropic API, requires API key |
| **OpenAI** | Cloud | OpenAI API, requires API key |

## Privacy

- **Speech recognition** runs 100% on-device via WhisperKit. Audio never leaves your Mac.
- **AI post-processing** with local providers (Apple Intelligence, Ollama) keeps text on your machine.
- **Cloud providers** (Claude, OpenAI) send transcribed text to external servers — only use if you're comfortable with that.

## License

MIT License — See [LICENSE](LICENSE) for details.
