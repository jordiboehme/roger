# Log Entries and Library - Design

Date: 2026-10-13
Status: phase 1 released in 0.23.0; phase 2 (0.24.0) approved 2026-10-13

## Goal

Roger gets "log entries", like a captain's log. A preset can save what you say as a Markdown file instead of typing it at the cursor. You bind it to Caps Lock plus a modifier and record short entries during the day.

Logs, meeting transcripts and file transcripts all live in one library folder. A new library window lets you search, filter, sort and manage hundreds or thousands of them. You can drag files or copy their paths into an agent or CLI tool.

Roger stays a menu bar app without a Dock icon. While the library window is open, it behaves like a normal app.

## Decisions from brainstorming

| Topic | Decision |
|---|---|
| Storage of log entries | One Markdown file per entry, each with its own frontmatter |
| Library location | One configurable root, default `~/Documents/Roger/` |
| Log entry content | Text only, no AI enrichment. Title = time + first 6 words |
| Audio | Per-preset "Keep audio" option (log presets). Meetings get "Keep audio after transcription" in settings, default on |
| Menu bar click | Popover stays. It gets "Open Library". A global shortcut opens the library |
| Library actions | Search, filter, sort, open, reveal, drag, copy path, copy folder path, rename (title), inline preview and edit, move to Trash |
| Index | In memory, kept current with FSEvents, behind a `LibraryIndex` protocol |
| Indicator for log mode | Waveform stays. Electric green accent, labels "Logging" and "Logged" |

Out of scope: storing normal dictations in the library, AI titles or tags, SQLite index, Spotlight integration.

## 1. Storage and file format

### Library root

`AppState.libraryRoot` (UserDefaults, default `~/Documents/Roger/`). It replaces `meetingRecordingsFolder` and `fileTranscriptOutputFolder`. There is one resolver for the default folder (today it is resolved in two places).

```
Roger/
├── Logs/YYYY/MM/
│   ├── 2026-10-13 14-32-05.md
│   └── 2026-10-13 14-32-05.m4a      (only with Keep audio)
├── Meetings/YYYY/MM/
│   └── 2026-10-13 09-00/            (session folder, content as today)
└── Transcripts/YYYY/MM/
    └── talk.mp4.md
```

- Year and month come from the recording start (logs, meetings) or the time of transcription (file transcripts), in local time.
- Roger never renames a file after it is written. Paths handed to agents stay valid. Renaming changes only the frontmatter `title` and the H1.
- Name collisions get the suffix ` 1`, ` 2` and so on (the same rule as meeting sessions today).
- The option "Save transcripts next to the source file" stays. Roger records each file written there in an external-paths list in Application Support (`external-transcripts.json`). The index scans these paths. Paths whose file is gone are removed from the list on the next scan.

### Log entry file

It follows the OKF decision of 2026-10-08 and is built with `TranscriptFrontmatter`. Key order: OKF keys first, then Roger's own keys.

```markdown
---
type: source
title: "Log 2026-10-13 14:32 - Called the supplier about the"
description: "Log entry recorded with Roger on 2026-10-13 at 14:32."
tags: [log]
generated: { by: roger/<version>, model: "FluidInference/parakeet-ultra-coreml", at: 2026-10-13T14:32:41+02:00 }
recorded_at: 2026-10-13
source_date: 2026-10-13
temporal_confidence: explicit
sources:
  - { id: audio, resource: "2026-10-13 14-32-05.m4a" }
status: stable
started_at: 2026-10-13T14:32:05+02:00
ended_at: 2026-10-13T14:32:38+02:00
duration_seconds: 33
preset: "Log"
language: "de"
---

# Log 2026-10-13 14:32

Called the supplier about the delayed shipment ...
```

- `sources` is present only when the audio was kept.
- `language` is present only when known (pinned or detected).
- The title uses the first 6 words of the processed text. Shorter texts use all words. The H1 is `Log <date> <time>`.

### Type recognition

The library recognises item kinds by the tags Roger already writes:

| Tags | Kind |
|---|---|
| `[log]` | Log entry |
| `[meeting, transcript]` | Meeting (the item is the session; its file is `transcript.md`) |
| `[transcript]` | File transcript |
| `[meeting, segment]` | Not listed. Part of its meeting |

A meeting session folder without `transcript.md` is an unfinished meeting.

## 2. Log capture

### Preset model

`DictationPreset` gets two fields. Both are decoded with `decodeIfPresent`, so saved presets keep working.

- `output: PresetOutput` - `.insertAtCursor` (default) or `.logEntry`
- `keepAudio: Bool` - default `false`, only used with `.logEntry`

New built-in preset **Log** with UUID `...0008`: filler removal and dedup on, no AI, `output = .logEntry`, `keepAudio = false`, `excludedFromRotation = true`. `mergeBuiltInPresets` adds it for existing users. Custom presets may use `.logEntry` with any pipeline, including AI steps.

Binding works through the existing `modifierBindings` (for example Caps+Option = Log). No new hotkey code is needed.

### Flow

1. Minimum duration check, transcription and post-processing run as for dictation.
2. In `AppCoordinator.runPipeline`, the insert step branches on `preset.output`:
   - `.insertAtCursor`: unchanged.
   - `.logEntry`: `LogEntryWriter.write(...)` writes the file. Nothing is typed. `trailingCharacter` and `sendReturnAfterInsert` are ignored.
3. With `keepAudio`, the captured 16 kHz mono buffer is encoded to AAC `.m4a` next to the `.md`.
4. `appState.lastTranscription` is set as usual. The popover entry links to the item in the library.

`LogEntryWriter` (new, `Services/LogEntryWriter.swift`) takes text, start and end time, preset name, language and an optional audio buffer. It returns the URL of the written `.md`. It creates the `Logs/YYYY/MM/` folders when needed.

### Indicator

- While a log preset records, the floating panel uses a new accent `logAccent` (electric green) and the label "Logging" with "as <Preset>" below. The waveform is unchanged.
- While processing: "Saving".
- After a successful save: "Logged" with a checkmark for about 1.5 s.

### Edge cases

- An empty transcript writes no file.
- A write failure (folder missing and cannot be created, disk full) keeps the text in `lastTranscription` with a copy button and shows an error banner, like the AI guardrail case today.
- During a meeting the trigger key toggles mic mute (existing behaviour). Log entries are not possible during a meeting.

### Settings

- Preset editor: "Output" picker ("Insert at cursor", "Save as log entry"). For log presets the "Keep audio" toggle appears, and trailing character and send Return are hidden.
- Recordings settings: library root folder with "Show in Finder", "Keep audio after transcription" for meetings (default on). When off, `mic.m4a` and `system.m4a` are deleted after the final transcript is written, and `sources` is left out of the frontmatter.

## 3. App shell

### Library window

- An `NSWindow` hosting `NSHostingController(rootView: LibraryView)`, managed by a small `LibraryWindowController`. It is the same pattern as onboarding (`RogerApp.swift`). A SwiftUI `Window` scene is not used because `openWindow` is not available from the AppKit popover.
- `sceneBridgingOptions` brings the SwiftUI toolbar and title into the window.
- One instance only. Opening it again brings it to the front.
- Size and position are saved with `setFrameAutosaveName`.

### Activation policy

- `LSUIElement` stays `true`.
- When the library opens: `NSApp.setActivationPolicy(.regular)`, then activate. Roger gets a Dock icon, appears in Cmd-Tab and shows its main menu. The `Settings` scene gives "Roger > Settings…" with Cmd-, automatically.
- When the library closes: `setActivationPolicy(.accessory)`.
- Clicking the Dock icon while it is visible brings the library to the front (`applicationShouldHandleReopen`).
- Settings and onboarding do not change the policy.

### Opening the library

- "Open Library" button in the popover.
- New global shortcut `KeyboardShortcuts.Name.openLibrary`, no default, set in General settings.
- The last-entry card in the popover opens the library with that item selected.

### Removed

The "Past Recordings" card in Recordings settings. The library replaces it.

## 4. Library UI

Three-column `NavigationSplitView`.

### Sidebar

All, Logs, Meetings, Transcripts, each with a count. "Unfinished" appears only when there are unfinished meetings, with a "Finalise" action per item (uses the existing `finaliseRecovered`).

### List

- Grouped by day with sticky headers ("Today", "Yesterday", "Mon, 12 Oct").
- Row: type icon, title, first line of text, time, duration, markers for audio, screenshot count and speaker count.
- Lazy `List` with multi-selection (Cmd, Shift).

### Toolbar

- Search field (Cmd-F). Full-text search over title and body, case-insensitive, all words must match, 150 ms debounce.
- Date filter: Any, Today, Last 7 days, Last 30 days, custom range.
- Sort: newest first (default), oldest first, title, duration.

### Detail pane

- Header: title (click to rename), metadata line (date, time, duration, language, preset, speakers). "Open Audio" when audio exists, opening it in the default app.
- Body: simple Markdown rendering (headings, bold, paragraphs). Meeting screenshots show as thumbnails at their position. Search matches are highlighted.
- Edit mode: plain-text editor for the body only. The frontmatter is kept unchanged. Cmd-S saves. Before saving, Roger checks the file's modification date. If the file changed on disk since editing started, Roger shows a warning with "Overwrite" and "Discard my changes" and does not save silently.
- The detail pane reads the file from disk each time an item is selected.

### Actions

| Action | Shortcut | Behaviour |
|---|---|---|
| Drag | | File URLs of the `.md` files (for meetings `transcript.md`) |
| Copy Path | Cmd-Shift-C | POSIX paths of the `.md` files, one per line |
| Copy Folder Path | | Meeting session folder, or the month folder for logs and transcripts |
| Open | Return | Default app for `.md` |
| Reveal in Finder | | Selects the files in Finder |
| Rename | | Edits `title` in the frontmatter and the H1. File name unchanged |
| Move to Trash | Cmd-Backspace | Logs go to Trash together with their `.m4a`. Meetings go as the whole folder, after a confirmation |

All actions work on the whole selection where it makes sense (not Rename).

### Empty states

Each kind has an empty state with a hint. For logs: "No log entries yet. Bind the Log preset to Caps+⌥ in Settings → Presets", with a button that opens the Presets settings.

## 5. Index

### Protocol

```swift
protocol LibraryIndex: Sendable {
    func items() async -> [LibraryItem]
    func search(_ query: LibraryQuery) async -> [LibraryItem]
    var changes: AsyncStream<Void> { get }
}
```

`LibraryQuery` holds kind, date range, search text and sort order. `LibraryItem` holds: url, folder url, kind, title, date, duration, language, preset, speaker count, screenshot count, hasAudio, first line, lowercase body for search.

### InMemoryLibraryIndex

- An actor. It scans `Logs/`, `Meetings/`, `Transcripts/`, the extra scan folders and the external-paths list.
- `LibraryFrontmatterParser` reads the keys Roger writes (scalars, inline maps, the `sources` and `tags` lists). It is not a general YAML parser. If a file cannot be parsed, it falls back to the file name and file dates, and the kind comes from the folder. The item stays visible.
- Built on the first library open, in the background, with a progress spinner in the window. It stays in memory while Roger runs.
- An `FSEventStream` on all scanned folders, with events coalesced over 0.5 s. Only changed paths are parsed again.
- Expected scale: a few thousand items, about 30 MB of text. If this ever grows far beyond that, a SQLite FTS5 implementation can replace it behind the same protocol.

## 6. Migration

At the first launch after the update:

- If the old meetings folder (`meetingRecordingsFolder` or the default `~/Documents/Roger Recordings/`) holds session folders, Roger asks: "Move N meetings to <root>/Meetings?" with **Move** and **Keep in place**.
  - Move: every session folder goes to `Meetings/YYYY/MM/`. Year and month come from the folder name `yyyy-MM-dd HH-mm`, or the folder creation date as fallback. `FileManager.moveItem` is used. Unfinished sessions are moved too. If a move fails, that folder stays where it is, and the old folder is added as an extra scan folder.
  - Keep in place: the old folder becomes an extra scan folder.
- A custom `fileTranscriptOutputFolder` becomes an extra scan folder. Its files are not moved.
- Transcripts written next to their source before this update are not known to Roger and will not appear in the library. The release notes say so.
- Extra scan folders are listed in Recordings settings and can be removed there.
- The migration runs once (flag in UserDefaults). It does not run while a meeting is recording.

## 7. Testing

- New test target `RogerTests` (Swift Testing) in `project.yml`. CI runs `xcodebuild test`.
- After `xcodegen generate`, restore the audio-input entitlement in `Resources/Roger.entitlements`.

Unit tests:

- `LibraryFrontmatterParser` reads what `TranscriptFrontmatter` writes (round trip for log, meeting and file transcript) and falls back on broken files.
- `LogEntryWriter`: folder path from the date, file name, collision suffix, title from first 6 words, `sources` only with audio.
- `InMemoryLibraryIndex`: kind detection, filter by kind and date, search with several words, every sort order, segment files not listed.
- Migration: folder name to `YYYY/MM`, fallback to creation date.
- Rename: only `title` and H1 change, every other byte stays the same.
- `DictationPreset` decoding of old JSON without the new fields.

Manual checks:

- Log recording by hotkey, with Keep audio on and off.
- Indicator colours and labels in log mode.
- Dock icon and Cmd-Tab with the library open and closed. Cmd-, from the library.
- Drag into Terminal and into Claude Code. Copy Path with several items.
- Edit with a file changed on disk by another process.
- Migration dialog with Move and with Keep in place.

## 8. Delivery

One spec, two implementation phases, each with its own plan:

1. **Foundation and log entries:** library root, migration, extra scan folders, external-paths list, `PresetOutput`, `keepAudio`, Log preset, `LogEntryWriter`, indicator, settings changes, meeting "Keep audio", test target. Usable on its own: entries land in `Logs/` and can be found in Finder.
2. **Library:** `LibraryWindowController`, activation policy, `openLibrary` shortcut, `LibraryIndex` and parser, `LibraryView` with all actions, removal of the Past Recordings card.

Phase 1 shipped in 0.23.0. Phase 2 ships in 0.24.0 together with the issues in section 9.

## 9. Additions for 0.24.0

### Carried over from 0.23.0

- The library lists meetings from the extra scan folders and transcripts from the external list (`ExternalTranscriptRegistry.existingFiles()`), next to everything under the library root.
- "Unfinished" in the sidebar shows exactly `AppCoordinator.pendingMeetingSessions` (unfinished per `MeetingSessionScanner.isUnfinished`, minus dismissed sessions). "Finalise" calls the existing retry. Dismissing there uses the existing persisted dismissal.
- The "Past Recordings" card in Recordings settings is removed. Library folder, extra folders and "Keep audio after transcription" stay.

### #8: a retry keeps edited segment files

- During finalisation, a segment file whose frontmatter says `status: stable` is moved aside as `<name>.previous.md` (`<name>.previous 1.md` and so on if taken) before the new version is written. An existing previous file is never overwritten.
- Draft segments (`status: draft`, written live during the meeting) are overwritten as before.
- The move-aside logic is one shared helper, also used for `transcript.previous.md`.

### #9: extra files after a retry

- Extra files of a meeting: `mic.leftover*.m4a`, `system.leftover*.m4a`, `mic.previous*.m4a`, `system.previous*.m4a`, `transcript.previous*.md` and segment `*.previous*.md`.
- `transcript.md` lists the extra audio files in `sources` with ids `mic-leftover`, `system-leftover`, `mic-previous`, `system-previous` (numbered suffix `-2`, `-3` when there are several), so agents see them.
- The meeting detail pane has an "Extra files" section: each file with Reveal in Finder and Move to Trash, plus "Clean up" that moves all extra files to the Trash after a confirmation. Never a permanent delete.
- When the audio is already safe in a leftover file and there is nothing to retry, the error says "Some audio could not be merged. It is saved as <file> in the meeting folder." and does not say "Try again".
