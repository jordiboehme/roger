<p align="center">
  <img src=".github/app-icon.png" width="256" alt="Roger">
</p>

# Roger

Speak. It types. Anywhere on your Mac.

Roger lives in your menu bar and turns your voice into text — in any app. Hold a hotkey, say what you need and it appears at your cursor. No cloud. No latency. Just your voice and Apple Silicon.

**Your voice stays on your machine.** Speech recognition runs entirely on-device using the Neural Engine. Cloud AI is available for text cleanup but always opt-in.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/V7V31T6CL9)

## Features

- **Near-instant results** — release the key and a full minute of dictation transcribes in well under a second, entirely on Apple Silicon's Neural Engine
- **Works everywhere** — Notes, Warp, VS Code, Slack, browsers — if it has a cursor, Roger can type into it
- **Drop files to transcribe** — drag an audio or video file onto the menu bar icon and Roger writes a `.txt` transcript next to it, or into a folder you configure. Works on `.m4a`, `.mp3`, `.wav`, `.mp4`, `.mov` and anything else AVFoundation can open. Always runs locally
- **Record meetings** — capture your mic and the system audio (what the other side says) on two separate tracks. Roger encodes both, transcribes each track and diarizes the remote one, then writes a diarized markdown transcript with `Me` and `Other 1, 2…` labels and absolute timestamps — ready for your knowledge base. Configurable output folder, optional global hotkey, optional mic-side diarization for shared-mic setups
- **Slide checkpoints** - drop a screenshot of a shared slide onto the recording overlay and Roger saves it next to a timestamped transcript segment of the audio since the last drop, while the recording keeps running. The session folder becomes a chronological record of what was said and shown, ready for an AI agent
- **Mute yourself everywhere** — while a meeting is recording, tap your dictation hotkey to toggle a system-level mic mute. One press silences you in Teams, Zoom, Meet and Roger's own track at once — no per-app setup, no plugin
- **Completely private** — Powered by [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidAudio](https://github.com/FluidInference/FluidAudio) on Apple Silicon. Your audio never leaves your Mac
- **Speaks your language** — English and German with automatic detection, plus 23 more European languages via Parakeet's multilingual model
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

- **macOS 14.4 Sonoma** or later (Core Audio Process Tap floor for meeting recording)
- **Microphone permission** (prompted on first launch)
- **Accessibility permission** (for text insertion and global hotkey)
- **System Audio Recording permission** (prompted on first meeting recording, only needed if you record meetings)

## How It Works

Roger captures audio from your chosen input device — system default or a specific mic pinned in Settings — transcribes it on-device using [NVIDIA Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML on the Neural Engine), optionally cleans up the text with an AI provider and inserts the result at your cursor. Transcription kicks off the instant you release the key and is fast enough that even a long dictation is ready in a moment. Insertion uses the Accessibility API directly, with a clipboard+paste fallback for Electron apps.

### Transcribing files

Drop any audio or video file on Roger's menu bar icon and it writes the transcript to a `.txt` next to the source — or into a folder you pick once. Video files have their audio track extracted on the fly. File transcription always uses an AI-free preset so it stays fully on-device; destination and preset live under Settings › File Transcription. A floating overlay shows progress with a Cancel button for long files.

### Recording meetings

Roger records your mic and everything you hear from the system on two separate tracks, encodes both as M4A on stop, then transcribes each track and diarizes the remote one to label participants. The result lands in a per-meeting folder under `~/Documents/Roger Recordings/` (configurable) with `mic.m4a`, `system.m4a` and `transcript.md`. The markdown carries YAML frontmatter and stamps every speaker turn with both an elapsed offset and the absolute local time, so a knowledge base can ingest it directly — and screenshots or notes you capture mid-call line up with what was said. Audio is chunked to disk every 30 minutes, so a crash mid-call doesn't lose work — Roger offers to resume finalizing on next launch. Start from the menu bar item or assign a global hotkey under Settings › Recordings. While a recording is live, your dictation hotkey toggles a system-level mic mute — one press silences you in the meeting app and on the recording alike, with no per-app setup. Turn on mic-side speaker detection there too if more than one person speaks into the same mic.

While a recording is live you can also drop screenshots of shared slides onto the floating overlay - straight from the macOS screenshot thumbnail, from Finder or from a browser. Each drop lands in the session folder named by its capture time and triggers a transcript segment covering the audio since the previous drop, written as a matching timestamped markdown file while the recording continues. Speaker labels stay stable across segments because every checkpoint transcribes the meeting from the start. On stop, Roger rewrites all segments from the final full-quality pass and weaves the screenshots into `transcript.md` as inline images, so the folder reads as a chronological dataset of what was said and shown - hand it to an AI agent and it can follow the meeting slide by slide.

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
