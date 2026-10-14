# Settings Overhaul (Roger 0.26.0, part B) Design

Roger's settings grew tab by tab. Today there are 10 toolbar tabs in two different styles (custom cards in seven tabs, the native grouped Form in Presets and AI Provider), copied helper views with different paddings, fixed widths and hard-coded font sizes. The settings window is SwiftUI's `Settings` scene, found by its window identifier and brought to the front by hand. It never shows in the Dock or in Cmd-Tab.

Part B gives Settings one structure, one look and its own window.

## Goals

- The settings people change most (Presets and Microphone) are one click away.
- Every pane looks the same: same margins, spacing, fonts, control sizes and help text placement.
- The settings window shows in the Dock and in Cmd-Tab while it is open.
- Settings open on the right pane from every place in the app.

## Decisions

| Topic | Decision |
|---|---|
| Structure | Sidebar grouped by task (System Settings style), not toolbar tabs. |
| Window | Own `NSWindow` with a `NavigationSplitView`, managed by `SettingsWindowController`. The SwiftUI `Settings` scene and `SettingsLink` go away. |
| Dock and Cmd-Tab | A shared app-window counter. Roger is `.regular` while the library or the settings window is open and `.accessory` after the last one closes. |
| Layout | One shared kit: grouped `Form`, standard section headers and footers, a note line under a row, status banner. No custom cards. |
| Popover | Unchanged. No microphone picker in the popover. |
| Research basis | Apple HIG Settings and Layout, System Settings, the macOS 26 grouped-form conventions. |

## 1. Structure

Sidebar, top to bottom:

| Group | Pane | SF Symbol (suggestion) |
|---|---|---|
| (none) | General | `gearshape` |
| (none) | Presets | `text.badge.star` |
| (none) | Microphone | `mic` |
| Transcription | Model | `waveform` |
| Transcription | AI Provider | `sparkles` |
| Transcription | Files | `doc.text` |
| Library | Library & Meetings | `books.vertical` |
| Library | Agents | `point.3.connected.trianglepath.dotted` |
| (none, bottom) | Permissions | `hand.raised` |
| (none, bottom) | About | `info.circle` |

Icons sit on small rounded colored squares, like System Settings. The window title is the pane name.

`SettingsPane` replaces `SettingsTab`. Every place that sets `pendingSettingsTab` maps to a pane:

| Old tab | New pane |
|---|---|
| General | General |
| Model | Model |
| Presets | Presets |
| Permissions | Permissions |
| Microphone | Microphone |
| AI Provider | AI Provider |
| File Transcription | Files |
| Recordings | Library & Meetings |
| Agents | Agents |
| About | About |

## 2. Pane contents

Every pane is a grouped `Form`. Rows have a label, a control on the trailing side and an optional one-line note under the label. Section footers hold longer explanations. Destructive actions sit at the end of their section and ask first.

### General
- Banner at the top when a required permission is missing (Microphone or Accessibility), with "Open Permissions".
- **Activation:** Mode (segmented: Push to talk, Toggle) with a note. Minimum recording and Maximum recording as steppers with their unit, each with a note where needed.
- **Shortcuts:** Dictation (the current dictation key, Caps Lock or F18, with a link to set up the Caps Lock remap when it is not active), Record a meeting, Open the library. All shortcut recorders live here.
- **Text insertion:** Restore the clipboard (switch, note).
- **Startup:** Launch at login (switch).

### Presets
- Preset list on the leading side of the pane (built-in and custom), with "+ New preset" and a context menu (Duplicate, Delete for custom presets, Reset for built-in presets).
- Detail on the trailing side:
  - **Preset:** Name, Language (menu, note), Output (menu: type at the cursor or save as a log entry).
  - **Processing:** Remove filler words, Remove repeated words, AI formatting (note names the current AI provider), AI rewrite. Switches.
  - **Output options:** shown for the chosen output only. Insert at cursor: Append at the end, Press Return after inserting. Log entry: Keep audio.
  - **Advanced** (collapsed by default): Formatting prompt, Rewrite prompt, Custom dictionary (the row shows the word count).
  - Footer for built-in presets: "Built-in presets can be changed. Reset brings back the original."

### Microphone
- **Input device:** device menu, current device name and its type as a note.
- **Level:** live level meter and a Test button.
- Note when the chosen device is disconnected, and the relaunch hint where it applies today.

### Model
- **Speech model:** model name, status (downloaded, downloading with progress, not downloaded), Download or Remove (asks first).

### AI Provider
- **Provider:** menu (Apple Intelligence, Ollama, Claude, OpenAI).
- One section for the chosen provider only: Apple Intelligence (availability note), Ollama (base URL, model), Claude (API key as a secure field, model), OpenAI (API key, model). Keys stay in the Keychain.

### Files
- **Output:** Save to (menu) with the resulting path as a note.
- **Processing:** Preset (menu), Speaker labels (switch).

### Library & Meetings
- **Library:** folder path with Choose, Reset, Reveal in Finder and Open Library. Extra scan folders as a list with Forget.
- **Meetings:** Keep audio, Speaker labels for system audio, Speaker labels for the microphone.
- **Reliability:** the existing stepper with its note.

### Agents
- The 0.25.0 content (library status, coding agents, Claude Desktop, manual setup, consumers) in the shared kit. Manual setup stays a collapsed section.

### Permissions
- One row per permission (Microphone, Accessibility, System Audio, Dictation key): status as a colored dot and text, and a fix button (Open System Settings, Test).

### About
- App icon, version, links (GitHub, Ko-fi), credits. Centered, not a form.

## 3. Shared kit

New folder `Roger/UI/Settings/`:

- `SettingsWindowController` (App): creates and shows the window, selects a pane, keeps the frame and the last pane.
- `SettingsRootView`: `NavigationSplitView` with the sidebar and the selected pane.
- `SettingsPane` (enum): id, title, symbol, color, group.
- `SettingsForm`: `Form { ... }.formStyle(.grouped)` with the standard content margins.
- `SettingsRow`: label, optional note, trailing control.
- `SettingsBanner`: icon, message, one action.

The copied `settingsCard` and `settingsRow` helpers in `SettingsView`, `RecordingsSettingsView`, `AgentsSettingsView` and `MicrophoneSettingsView` go away. No fixed font sizes and no fixed widths in panes, except the preset list width.

## 4. Window

- `SettingsWindowController.show(_ pane: SettingsPane? = nil)` shows the window and selects the pane. A second call brings the same window to the front.
- Default size 720 × 540, minimum 640 × 460. Frame and last pane are remembered (`setFrameAutosaveName`, UserDefaults for the pane).
- Minimize is available (the window is in the Dock while open). Full screen is off.
- Cmd-, opens Settings: `CommandGroup(replacing: .appSettings)` while Roger is `.regular`, and the popover's Settings button.
- Every link that opens Settings (popover, library empty state, permission banner, preset "Edit presets") calls `SettingsWindowController.show(pane)`.
- The SwiftUI `Settings` scene, `SettingsLink`, `activateSettingsWindow()` and the `com_apple_SwiftUI_Settings_window` lookup are removed.

### App windows and the Dock

New `AppWindowPresence` (App, `@MainActor`):

- `enter()` when an app window opens: on the first one, `NSApp.setActivationPolicy(.regular)`, then activate the app.
- `leave()` from `windowWillClose` of that window (filtered to the window itself): after the last one, `.accessory`.
- `LibraryWindowController` uses it instead of setting the policy itself. Closing the library while Settings is open keeps Roger in the Dock.
- The policy switches before the window is shown, so the Dock icon does not flash.

## 5. Behavior that stays

- All settings keep their keys and values. Nothing is reset or migrated.
- The popover is unchanged.
- Onboarding is unchanged.

## 6. Snapshots

The DEBUG snapshot mode gets settings panes: with `-RogerSnapshotDir <dir> -RogerSnapshotSettings YES`, Roger opens the settings window, renders each pane to `settings-<pane>.png` and quits. The release notes and reviews use these images.

## Testing

- Unit tests:
  - `SettingsPane` mapping from every old tab value.
  - `AppWindowPresence` counting: library then settings, close in both orders, the policy after each step, using an injected policy setter.
  - `SettingsWindowController.show(pane)` selects the pane and reuses the window.
- Snapshot run renders all ten panes without errors.
- Manual checks:
  - Cmd-Tab and the Dock while Settings is open, alone and together with the library.
  - Every "open Settings" link lands on its pane.
  - Each pane at the minimum size: nothing cut off.
  - Dark mode.

## Delivery

1. `AppWindowPresence` and `SettingsWindowController` with the old content in the new window (Dock and Cmd-Tab work).
2. Shared kit, sidebar and `SettingsPane`, all links switched over.
3. General and Permissions.
4. Presets.
5. Microphone, Model, AI Provider, Files.
6. Library & Meetings, Agents, About.
7. Snapshot mode and removal of the old helpers and the `Settings` scene.
