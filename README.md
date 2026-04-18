<p align="center">
  <img src=".github/app-icon.png" width="256" alt="Roger">
</p>

# Roger

Speak. It types. Anywhere on your Mac.

Roger lives in your menu bar and turns your voice into text — in any app. Hold a hotkey, say what you need and it appears at your cursor. No cloud. No latency. Just your voice and Apple Silicon.

**Your voice stays on your machine.** Speech recognition runs entirely on-device using the Neural Engine. Cloud AI is available for text cleanup but always opt-in.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/V7V31T6CL9)

## Features

- **Near-instant results** — a full minute of dictation lands in about two seconds after you release the key. On-device streaming transcription runs on Apple Silicon's Neural Engine while you speak
- **Works everywhere** — Notes, Warp, VS Code, Slack, browsers — if it has a cursor, Roger can type into it
- **Completely private** — Powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) on Apple Silicon. Your audio never leaves your Mac
- **Speaks your language** — English and German with automatic detection. More languages via Whisper's multilingual models
- **Cheat-sheet menu bar** — one glance at the popup tells you which Caps Lock combo maps to which preset
- **Quick copy** — click the last-dictation preview in the menu bar to drop it on the clipboard, handy when the insertion target wasn't quite right
- **Modifier-bound presets** — bind your favorite presets to `⇪ + ⇧/⌥/⌃/⌘` for instant access
- **Switch presets mid-sentence** — hold Caps Lock and tap ← / → to swap how Roger will process what you're still dictating. The overlay updates live
- **Seven built-in presets** — Plain, Polished, Professional and Code for serious work. Caveman, Yoda and Emoji for the rest. Or build your own with a custom prompt and dictionary
- **Bring your own AI** — Apple Intelligence, Ollama, Claude or OpenAI for post-processing. Local-first, cloud if you want it
- **Auto-submit prompts** — configure a preset to append a newline or press Return so a dictated prompt fires straight into the chatbox
- **Pick your mic** — dedicated Microphone tab lets you pin a specific input or follow the system default
- **Caps Lock push-to-talk** — hold to listen, release to transcribe. Toggle mode and configurable minimum duration if you prefer
- **Session safety** — a configurable recording cap (default two minutes) auto-stops long sessions, with a live countdown that intensifies in the final 10 seconds
- **Stays out of the way** — menu bar only, no Dock icon. A capsule overlay tracks the whole pipeline: Listening while you speak, Thinking while Roger processes

## Installation

### Homebrew (recommended)

New to [Homebrew](https://brew.sh/)? It's the standard macOS package manager — install it first, then:

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
- **Accessibility permission** (for text insertion and global hotkey)

## How It Works

Roger captures audio from your chosen input device — system default or a specific mic pinned in Settings — transcribes it on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (a CoreML port of [OpenAI Whisper](https://github.com/openai/whisper)), optionally cleans up the text with an AI provider and inserts the result at your cursor. Transcription streams while you're still speaking, so the text lands almost the instant you release the key. Insertion uses the Accessibility API directly, with a clipboard+paste fallback for Electron apps.

### Presets

| Preset | What it does |
|--------|-------------|
| **Plain** | Strips filler words and repeated words. No AI needed. |
| **Polished** | Adds punctuation, capitalization and paragraph breaks. |
| **Professional** | Full cleanup with an AI rewrite for send-ready prose. |
| **Code** | Preserves technical terms, function names and code references. |
| **Caveman** | Drops articles and pleasantries. Short, blunt, fragments OK. |
| **Yoda** | Rewrites in Yoda's speech pattern. Fun, you will have. |
| **Emoji** | Sprinkles emojis through the text the way a friend would text. |
| **Custom** | Your own pipeline — pick which steps run, write your own prompts, add a dictionary. |

Each preset also controls what lands at the cursor: append nothing, a space or a newline, and optionally press Return after insertion — useful for firing dictated prompts directly into a chatbox.

### AI Providers

| Provider | Type | Notes |
|----------|------|-------|
| **Apple Intelligence** | Local | On-device, macOS 26+, zero setup |
| **Ollama** | Local | Your Mac, your NAS, your homelab |
| **Claude** | Cloud | Anthropic API |
| **OpenAI** | Cloud | OpenAI API |

## Privacy

Roger is built around a simple principle: your voice is yours.

- **Speech recognition** is 100% on-device. Audio never leaves your Mac.
- **Local AI** (Apple Intelligence, Ollama) keeps your text on your machine too.
- **Cloud providers** are opt-in and clearly marked. Your text is sent to their servers only if you choose to.

## License

MIT License — See [LICENSE](LICENSE) for details.
