# Settings Overhaul (Roger 0.26.0, part B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roger's settings become one System-Settings-like window of their own (sidebar grouped by task, grouped `Form` panes in one shared kit) that shows in the Dock and in Cmd-Tab while it is open and opens on the right pane from every place in the app.

**Architecture:** `SettingsWindowController` (App) owns an `NSWindow` with an `NSHostingController` around `SettingsRootView` (`NavigationSplitView`: sidebar of `SettingsPane`s, the selected pane on the right), the same pattern as `LibraryWindowController`. A shared `AppWindowPresence` counts the open app windows (library, settings) and switches the activation policy. Every pane is a `SettingsForm` (grouped `Form`) built from `SettingsRow`, `SettingsToggle`, `SettingsBanner` and `SettingsStatus` in `Roger/UI/Settings/`. Every "open Settings" place calls `coordinator.openSettings(pane)`. A DEBUG snapshot mode renders every pane to PNG so the look can be reviewed on a phone.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (`NavigationSplitView`, `Form` with `.formStyle(.grouped)`, `LabeledContent`, `DisclosureGroup`), AppKit (`NSWindow`, `NSHostingController`, `NSSplitView`), Core Audio (transport type), KeyboardShortcuts 3.1.0, XcodeGen 2.46.0, Xcode 27, Swift Testing, macOS 15+ on Apple Silicon.

**Spec:** `docs/superpowers/specs/2026-10-14-settings-overhaul-design.md` (binding). Part A (`docs/superpowers/plans/2026-10-14-text-input-and-fixes-0.26.0.md`) is implemented first, on the same branch.

## Global Constraints

From the spec (verbatim values):

- Structure: "Sidebar grouped by task (System Settings style), not toolbar tabs."
- Sidebar, top to bottom: (none) General `gearshape`, Presets `text.badge.star`, Microphone `mic`; Transcription: Model `waveform`, AI Provider `sparkles`, Files `doc.text`; Library: Library & Meetings `books.vertical`, Agents `point.3.connected.trianglepath.dotted`; (none, bottom) Permissions `hand.raised`, About `info.circle`. "Icons sit on small rounded colored squares, like System Settings. The window title is the pane name."
- Old tab to new pane: General > General, Model > Model, Presets > Presets, Permissions > Permissions, Microphone > Microphone, AI Provider > AI Provider, File Transcription > Files, Recordings > Library & Meetings, Agents > Agents, About > About.
- Window: "Own `NSWindow` with a `NavigationSplitView`, managed by `SettingsWindowController`." "Default size 720 × 540, minimum 640 × 460. Frame and last pane are remembered (`setFrameAutosaveName`, UserDefaults for the pane)." "Minimize is available (the window is in the Dock while open). Full screen is off."
- "`SettingsWindowController.show(_ pane: SettingsPane? = nil)` shows the window and selects the pane. A second call brings the same window to the front."
- "Cmd-, opens Settings: `CommandGroup(replacing: .appSettings)` while Roger is `.regular`, and the popover's Settings button."
- "Every link that opens Settings (popover, library empty state, permission banner, preset "Edit presets") calls `SettingsWindowController.show(pane)`."
- `AppWindowPresence`: "`enter()` when an app window opens: on the first one, `NSApp.setActivationPolicy(.regular)`, then activate the app." "`leave()` from `windowWillClose` of that window (filtered to the window itself): after the last one, `.accessory`." "Closing the library while Settings is open keeps Roger in the Dock." "The policy switches before the window is shown, so the Dock icon does not flash."
- Layout: "One shared kit: grouped `Form`, standard section headers and footers, a note line under a row, status banner. No custom cards." "No fixed font sizes and no fixed widths in panes, except the preset list width."
- "Every pane is a grouped `Form`. Rows have a label, a control on the trailing side and an optional one-line note under the label. Section footers hold longer explanations. Destructive actions sit at the end of their section and ask first."
- Presets footer for built-in presets: "Built-in presets can be changed. Reset brings back the original."
- "All settings keep their keys and values. Nothing is reset or migrated." "The popover is unchanged." "Onboarding is unchanged."
- Snapshots: "with `-RogerSnapshotDir <dir> -RogerSnapshotSettings YES`, Roger opens the settings window, renders each pane to `settings-<pane>.png` and quits."

Project rules:

- Work on branch `feat/text-input-and-fixes` in `/Users/jordi/git/roger` (checked out). Do not switch branches. Part A is done before Task 1 starts.
- **Part A touched some of the same files** (`RogerApp.swift`, `LibraryWindowController.swift`, `LibraryEmptyState.swift`, `AgentsSettingsView.swift`, `AppCoordinator.swift`). Every step on those files starts by reading the file as it is now and makes anchored edits of the named lines only. Never replace such a file as a whole. If an anchor text changed in part A, apply the same change to the new text and say so in the task report.
- macOS 15.0 deployment target, Swift 6 strict concurrency with no new warnings, `@MainActor` for `@Observable` types SwiftUI observes. arm64 only.
- Logging via `os.Logger` with subsystem `com.jordiboehme.roger`.
- Commits: plain conventional-commit messages. NEVER add `Co-Authored-By`, "Generated with Claude Code" or any AI attribution.
- User-facing strings (UI text, alerts, notes, footers, script messages, README): no em-dash "—" or en-dash "–" (use "-"), no Oxford comma ("A, B and C"), short plain sentences, everyday words.
- Debug build: `cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | tail -20`. Never pass `CONFIGURATION_BUILD_DIR` for Debug.
- App tests (hosted in Roger.app, the scheme also runs RogerKitTests): `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -40`. Add `-only-testing:RogerTests/<SuiteName>` for one suite. "Restarting after unexpected exit" in the output is a crash, not a pass.
- New or deleted files need the project regenerated: `cd /Users/jordi/git/roger/Roger && xcodegen generate`. After every `xcodegen generate`: run `git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements` (xcodegen empties it), check `git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements` prints nothing, and commit the regenerated `Roger/Roger.xcodeproj` with the task.
- Tests must NEVER construct `AppState` or `AppCoordinator`, never read or write `UserDefaults.standard` (or any `UserDefaults(suiteName:)`, they leave files in `~/Library/Preferences`), never touch `~/Documents`, never put a window on screen. Use the injected closures shown in the tasks.
- **Tests that call a `static func` of a SwiftUI `View` type are `@MainActor`.** `View` is main-actor isolated; a nonisolated test that calls such a function compiles but crashes at run time (`dispatch_assert_queue`, seen 2026-10-14).
- `AGENTS.md` is in `.gitignore`. Edit it in place (Task 9), never `git add` it.
- Do not bump `MARKETING_VERSION` and do not write release notes. The release is a separate step.
- **Snapshot review.** Every UI task (Tasks 4 to 8) ends with `scripts/settings-snapshots.sh` (added in Task 4) into a fresh folder, then lists the PNG files of the touched panes and opens them (Read tool on the PNG). The report of the task names the folder, so the reviewer can send the images to Jordi's phone. The snapshot shows the Debug build's own permissions (usually "Not allowed"), that is expected.

## Review Focus

1. The library is open, Settings is opened, then the library is closed: Roger must stay in the Dock and in Cmd-Tab until Settings closes too, in both closing orders. (Task 1: `libraryThenSettingsClosingLibraryFirst`, `libraryThenSettingsClosingSettingsFirst`.)
2. A window that is already open is shown again (popover button, Cmd-,, Dock click, library shortcut): it must be counted once, so one close makes Roger a menu bar app again and it never gets stuck in the Dock. (Task 1: `showingAnOpenWindowAgainCountsOnce`; Task 3: `showSelectsThePaneAndReusesTheWindow`.)
3. The remembered pane is unknown (an older or newer Roger wrote another value, or the 0.25 tab names `recordings` and `fileTranscription`): Settings must open on a valid pane, never crash. (Task 2: `startsOnTheStoredPane`, `everyOldTabHasItsPane`, `unknownValuesAreNil`.)
4. A built-in preset that the user only hid from the Caps Lock rotation is not "changed", and Reset keeps that choice and the id (so modifier bindings and the main preset still point at it). (Task 6: `resetKeepsTheRotationChoice`, `resetBringsBackTheShippedPreset`.)
5. Caps Lock status with several keyboards, other key mappings or no mapping at all: "Caps Lock" only when one block maps Caps Lock to F18. (Task 5: `findsTheMappingInRealOutput`, `otherMappingsDoNotCount`, `emptyMappingIsOff`, `findsItAmongOtherMappingsAndInHex`.)

Also checked by hand (no unit test reaches them): deleting the selected custom preset (Task 6 binds the detail by id, not by index, so a delete never writes into another preset), and stored durations outside the stepper ranges (Task 5, Ruling 13).

## Rulings

Where the spec is silent, unverifiable or in conflict with the code, these rulings apply. Reviewers: treat them as part of the spec.

1. **Delivery order.** The spec lists the snapshot mode last. It comes in Task 4 here, right after the new window works, so every pane task (5 to 8) can be reviewed from PNG files on a phone. Spec steps 1 and 2 are Tasks 1 to 3, steps 3 to 6 are Tasks 5 to 8, the rest of step 7 is Task 9.
2. **The empty `Settings` scene stays.** A SwiftUI `App` needs one scene, and `.commands { CommandGroup(replacing: .appSettings) }` needs a scene to sit on. `RogerApp.body` is `Settings { EmptyView() }.commands { ... }`. Its own menu item is replaced, so this empty window can never open. `SettingsView`, `SettingsLink`, `activateSettingsWindow()` and the `com_apple_SwiftUI_Settings_window` lookup are removed as the spec says. This also keeps part A's Ruling 18 (the body never touches `sharedCoordinator`; the command's action calls `appDelegate.showSettings()` only when clicked).
3. **AppWindowPresence** keeps a set of open windows (`.library`, `.settings`), not a counter, so a second `enter` for an open window changes nothing. It only switches the policy. Activating the app stays in the window controllers (`makeKeyAndOrderFront`, then on the next run loop turn `NSApp.activate` and `makeKeyAndOrderFront` again), because it needs the window. The library controller filters `windowWillClose` to its own window too.
4. **Opening Settings.** `AppCoordinator.openSettings(_ pane: SettingsPane? = nil)` calls `settingsOpener`, which the AppDelegate sets (same pattern as `openLibrary`/`libraryOpener`). `AppDelegate.showSettings(_:)` closes the popover and calls `SettingsWindowController.show(pane)`. A pane inside Settings that links to another pane (General banner, "Set Up Caps Lock") sets `SettingsNavigation.selection` directly.
5. **`SettingsTab` and `pendingSettingsTab` are deleted.** The old tab names live on in `SettingsPane(storedValue:)` (`"fileTranscription"` > Files, `"recordings"` > Library & Meetings, the others by name), which reads the remembered pane (key `settingsLastPane`). That is the spec's "mapping from every old tab value" test.
6. **Window title and sidebar width.** The window title comes from `.navigationTitle(pane.title)` through `sceneBridgingOptions = [.toolbars, .title]`, as in the library window. `.toolbar(removing: .sidebarToggle)` hides the sidebar button. SwiftUI ignores `navigationSplitViewColumnWidth` in this AppKit window (seen 2026-10-14: the sidebar started at about 144 pt and cut "Library & Meetings"), so the controller sets the first divider of the `NSSplitView` to 200 pt once after the first show. The user can still drag it.
7. **Dock click** (`applicationShouldHandleReopen`): the library comes to the front when it is open, else Settings when it is open.
8. **Level meter.** A live meter would keep the microphone open (and the orange privacy dot on) as long as the pane is visible. The meter shows the peak of the last Test instead. The footer says so.
9. **Device type** is the Core Audio transport type (`kAudioDevicePropertyTransportType`): Built-in, USB, Bluetooth, Thunderbolt, HDMI, DisplayPort, AirPlay, iPhone, Aggregate device, Virtual device.
10. **Caps Lock status.** `CapsLockRemap.isActiveNow()` reads `hidutil property --get UserKeyMapping` off the main actor and looks for one block with `HIDKeyboardModifierMappingSrc = 30064771129` (0x700000039, Caps Lock) and `HIDKeyboardModifierMappingDst = 30064771181` (0x70000006D, F18), the values `HotkeyManager.remapCapsLockToF18()` sets. The General row shows "Caps Lock", "F18" (not set up) or "Caps Lock or F18" (still checking). "Set Up Caps Lock" opens the Permissions pane, where "Turn On" (the old Enable Remap) and "Keep at Login" (the old Persist for Login) live.
11. **Built-in presets can be changed** (spec, a behavior change from 0.25 where their steps were locked). Reset brings back the shipped preset from `DictationPreset.builtInPresets` and keeps the id and `excludedFromRotation` (set in the list's context menu, not in the preset). Reset is offered only when the preset differs (`isChangedBuiltIn`), and asks first. A saved built-in with an older shipped prompt counts as changed, so Reset also brings the current prompt. Custom presets have Delete (asks first) instead. Both sit in the last section of the detail and in the context menu. "+ New Preset" replaces the + / - / duplicate bar; Duplicate is in the context menu.
12. **Settings the spec does not list stay**: the meeting transcript preset menu (Library & Meetings > Meetings), "Custom dictionary" switch and words (Presets > Advanced), both prompts (always in Advanced, not only when the step is on), the preset context menu (main preset, Caps Lock modifiers, hide from rotation), Retry, Reset and Ask Again, the F18 check on both shortcut recorders, `syncLaunchAtLogin` on appear, the `activationMode` > `hotkeyManager` hand-over, the 2 s and 3 s refresh timers, `libraryChanges.reconcile()` after Choose and Reset, Relaunch Roger on a stuck audio system, the Ollama connection test.
13. **Steppers.** Minimum recording 0 to 10 s in 0.5 s steps, maximum recording 30 to 600 s in 30 s steps (the clamp in `AppState.maximumRecordingDuration`), audio chunk 5 to 60 min in 5 min steps (unchanged). A stored minimum outside 0 to 10 (typed into the old text field) stays as it is until the stepper is used. Durations show as "1.5 s", "2 min", "1 min 30 s" in the user's locale.
14. **AI Provider** is a menu (spec), each entry with "(local)" or "(cloud)" so the old Local and Cloud badges are not lost.
15. **Snapshot files.** Per pane: `settings-<pane>.png` (light, 720 × 1000 so the whole pane is visible), `settings-<pane>-dark.png` and `settings-<pane>-min.png` (640 × 460, the "nothing cut off" check). `<pane>` is the raw value: general, presets, microphone, model, aiProvider, files, library, agents, permissions, about. 30 files in all. The run remembers no pane and no frame and changes no setting.
16. **Fixed sizes** that remain: the preset list width (180 pt, spec), the sidebar icon square (20 pt), the status dot (8 pt) and the minimum/maximum width of the two progress bars (60 to 140 pt). No fixed font sizes: notes use `.subheadline`, code uses `.body.monospaced()` and `.callout.monospaced()`.
17. **Part A carried over.** Panes rewritten here keep what part A changed in the old views: `LibraryPane`'s Reset calls `LibraryLayout.createRootIfDefault(state.libraryLayout)` before `reconcile()` (part A Task 5); `AgentsPane` keeps part A's `manualChoice` state, the awaited `AgentsController.live()` and the detached `perform(_:)` (part A Task 22); "Relaunch Roger" keeps calling `coordinator.relaunchApp()`, which part A routes through the quit question (part A Task 13); `RogerApp`'s `AppLaunch.isRunningTests` stays because `applicationDidFinishLaunching` still uses it (part A Task 21). Before writing a pane, grep part A's plan (`docs/superpowers/plans/2026-10-14-text-input-and-fixes-0.26.0.md`) for the old view's name and port any other change it made.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `Roger/App/AppWindowPresence.swift` | 1 | Open app windows, activation policy |
| `Roger/App/LibraryWindowController.swift` | 1 | Uses `AppWindowPresence` |
| `Roger/UI/Settings/SettingsPane.swift` | 2 | Panes: title, symbol, color, sidebar group, stored value |
| `Roger/UI/Settings/SettingsNavigation.swift` | 2 | Selected pane, remembered pane |
| `Roger/App/SettingsWindowController.swift` | 3 | The settings window |
| `Roger/UI/Settings/SettingsRootView.swift` | 3, 5-8 | Sidebar, pane icon, pane switch |
| `Roger/App/RogerApp.swift` | 3, 4 | Scene, Cmd-, command, AppDelegate wiring, snapshot start |
| `Roger/App/AppCoordinator.swift`, `Roger/App/AppState.swift` | 3 | `openSettings`; `pendingSettingsTab` gone |
| `Roger/UI/MenuBarView.swift`, `Roger/UI/Library/LibraryEmptyState.swift` | 3 | Links call `openSettings` |
| `Roger/App/SettingsSnapshotRunner.swift`, `scripts/settings-snapshots.sh` | 4 | Snapshot mode |
| `Roger/App/LibrarySnapshotRunner.swift` | 4 | `settle` and `render` shared |
| `Roger/UI/Settings/SettingsKit.swift`, `SettingsFormat.swift` | 5, 7 | Shared kit |
| `Roger/Services/CapsLockRemap.swift` | 5 | Caps Lock status |
| `Roger/UI/Settings/GeneralPane.swift`, `PermissionsPane.swift` | 5 | Panes |
| `Roger/Models/PresetEditing.swift`, `Roger/UI/Settings/PresetsPane.swift` | 6 | Reset, duplicate, new; Presets pane |
| `Roger/Services/AudioDeviceLookup.swift` | 7 | Transport type |
| `Roger/UI/Settings/MicrophonePane.swift`, `ModelPane.swift`, `AIProviderPane.swift`, `FilesPane.swift` | 7 | Panes |
| `Roger/UI/Settings/LibraryPane.swift`, `AgentsPane.swift`, `AboutPane.swift` | 8 | Panes |
| `Roger/UI/SettingsView.swift`, `PresetsSettingsView.swift`, `MicrophoneSettingsView.swift`, `AIProviderSettingsView.swift`, `RecordingsSettingsView.swift`, `AgentsSettingsView.swift` | 3, 5-8 | Emptied and deleted pane by pane |
| `README.md`, `AGENTS.md` | 9 | Docs |
| `Roger/RogerTests/*` | 1-7 | Named per task |

---

### Task 1: AppWindowPresence and the library window

**Files:**
- Create: `Roger/App/AppWindowPresence.swift`
- Modify: `Roger/App/LibraryWindowController.swift` (doc comment, stored properties, `init`, `show`, `windowWillClose`)
- Test: `Roger/RogerTests/AppWindowPresenceTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `@MainActor final class AppWindowPresence` with `enum Window { case library, settings }`, `static let shared`, `init(setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void)`, `func enter(_ window: Window)`, `func leave(_ window: Window)`, `var isRegular: Bool`, `private(set) var openWindows: Set<Window>`. `LibraryWindowController.init(coordinator:indexStore:presence:)` with `presence: AppWindowPresence = .shared`.

- [ ] **Step 1: Write the failing test**

Create `Roger/RogerTests/AppWindowPresenceTests.swift`:

```swift
import AppKit
import Testing
@testable import Roger

@MainActor
struct AppWindowPresenceTests {
    /// Records every policy change instead of touching NSApp.
    final class PolicyLog {
        var calls: [NSApplication.ActivationPolicy] = []
    }

    private func make() -> (AppWindowPresence, PolicyLog) {
        let log = PolicyLog()
        let presence = AppWindowPresence { log.calls.append($0) }
        return (presence, log)
    }

    @Test func firstWindowMakesRogerRegular() {
        let (presence, log) = make()
        presence.enter(.library)
        #expect(log.calls == [.regular])
        #expect(presence.isRegular)
    }

    @Test func libraryThenSettingsClosingLibraryFirst() {
        let (presence, log) = make()
        presence.enter(.library)
        presence.enter(.settings)
        #expect(log.calls == [.regular])
        presence.leave(.library)
        #expect(log.calls == [.regular])
        #expect(presence.isRegular)
        presence.leave(.settings)
        #expect(log.calls == [.regular, .accessory])
        #expect(!presence.isRegular)
    }

    @Test func libraryThenSettingsClosingSettingsFirst() {
        let (presence, log) = make()
        presence.enter(.library)
        presence.enter(.settings)
        presence.leave(.settings)
        #expect(log.calls == [.regular])
        presence.leave(.library)
        #expect(log.calls == [.regular, .accessory])
    }

    @Test func showingAnOpenWindowAgainCountsOnce() {
        let (presence, log) = make()
        presence.enter(.library)
        presence.enter(.library)
        presence.leave(.library)
        #expect(log.calls == [.regular, .accessory])
        #expect(presence.openWindows.isEmpty)
    }

    @Test func leaveWithoutEnterChangesNothing() {
        let (presence, log) = make()
        presence.leave(.settings)
        #expect(log.calls.isEmpty)
        presence.enter(.library)
        presence.leave(.settings)
        #expect(log.calls == [.regular])
    }

    @Test func openingAgainAfterTheLastCloseIsRegularAgain() {
        let (presence, log) = make()
        presence.enter(.settings)
        presence.leave(.settings)
        presence.enter(.settings)
        #expect(log.calls == [.regular, .accessory, .regular])
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to verify it fails**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/AppWindowPresenceTests 2>&1 | tail -20`
Expected: build fails with "cannot find 'AppWindowPresence' in scope".

- [ ] **Step 3: Write the implementation**

Create `Roger/App/AppWindowPresence.swift`:

```swift
import AppKit

/// Keeps track of Roger's open app windows (library and settings). While at
/// least one is open, Roger is a regular app with a Dock icon and a place in
/// Cmd-Tab. After the last one closes, it is a menu bar app again.
@MainActor
final class AppWindowPresence {
    enum Window: Hashable, CaseIterable {
        case library
        case settings
    }

    static let shared = AppWindowPresence { policy in
        _ = NSApp.setActivationPolicy(policy)
    }

    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private(set) var openWindows: Set<Window> = []

    init(setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void) {
        self.setPolicy = setPolicy
    }

    /// True while at least one app window is open.
    var isRegular: Bool { !openWindows.isEmpty }

    /// Call before the window is shown, so the Dock icon does not flash.
    /// A second call for a window that is already open changes nothing.
    func enter(_ window: Window) {
        let wasEmpty = openWindows.isEmpty
        guard openWindows.insert(window).inserted else { return }
        if wasEmpty { setPolicy(.regular) }
    }

    /// Call from `windowWillClose` of that window.
    func leave(_ window: Window) {
        guard openWindows.remove(window) != nil else { return }
        if openWindows.isEmpty { setPolicy(.accessory) }
    }
}
```

- [ ] **Step 4: Switch the library window over**

Read `Roger/App/LibraryWindowController.swift` as part A left it. Make these anchored edits.

Doc comment of the class, replace:

```swift
/// Owns the library window: an NSWindow hosting `LibraryView`, created once
/// and reused. While it is open, Roger is a regular app (Dock icon, Cmd-Tab,
/// main menu with Settings and Cmd-,). When it closes, Roger is a menu bar
/// app again. A SwiftUI `Window` scene is not used because `openWindow` is
/// not reachable from the AppKit popover.
```

with:

```swift
/// Owns the library window: an NSWindow hosting `LibraryView`, created once
/// and reused. While it is open, Roger is a regular app (Dock icon, Cmd-Tab,
/// main menu with Settings and Cmd-,), counted by `AppWindowPresence`
/// together with the settings window. A SwiftUI `Window` scene is not used
/// because `openWindow` is not reachable from the AppKit popover.
```

After `private let indexStore: LibraryIndexStore` add:

```swift
    private let presence: AppWindowPresence
```

Replace the initializer:

```swift
    init(coordinator: AppCoordinator, indexStore: LibraryIndexStore) {
        self.coordinator = coordinator
        self.indexStore = indexStore
    }
```

with:

```swift
    init(coordinator: AppCoordinator, indexStore: LibraryIndexStore, presence: AppWindowPresence = .shared) {
        self.coordinator = coordinator
        self.indexStore = indexStore
        self.presence = presence
    }
```

In `show(selecting:)` replace:

```swift
        isOpen = true
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
```

with:

```swift
        isOpen = true
        // Before the window is shown, so the Dock icon does not flash.
        presence.enter(.library)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
```

In `windowWillClose(_:)` replace the first lines:

```swift
    func windowWillClose(_ notification: Notification) {
        isOpen = false
```

with:

```swift
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        isOpen = false
```

and replace:

```swift
        model?.windowClosed()
        NSApp.setActivationPolicy(.accessory)
```

with:

```swift
        model?.windowClosed()
        // Roger stays in the Dock while the settings window is open.
        presence.leave(.library)
```

Check: `grep -n "setActivationPolicy" /Users/jordi/git/roger/Roger/App/*.swift` prints only the line in `AppWindowPresence.swift`.

- [ ] **Step 5: Run the tests and the build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/AppWindowPresenceTests 2>&1 | tail -20`
Expected: `Test run with 6 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Manual check**

Run Roger from Xcode. Open the library from the popover: Roger appears in the Dock and in Cmd-Tab. Open it again from the popover while it is open, then close it: Roger leaves the Dock. Minimize the library: Roger stays in the Dock; a click on the Dock icon brings the library back.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/App/AppWindowPresence.swift Roger/App/LibraryWindowController.swift Roger/RogerTests/AppWindowPresenceTests.swift Roger/Roger.xcodeproj
git commit -m "feat: count open app windows for the Dock icon"
```

---

### Task 2: SettingsPane and the remembered pane

**Files:**
- Create: `Roger/UI/Settings/SettingsPane.swift`, `Roger/UI/Settings/SettingsNavigation.swift`
- Test: `Roger/RogerTests/SettingsPaneTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum SettingsPane: String, CaseIterable, Identifiable, Hashable` with cases `general, presets, microphone, model, aiProvider, files, library, agents, permissions, about` (sidebar order), `title`, `symbol`, `color: Color`, `sidebarGroup: SidebarGroup`, `init?(storedValue: String)`; `enum SettingsPane.SidebarGroup: CaseIterable { case top, transcription, library, bottom }` with `title: String?` and `panes: [SettingsPane]`. `struct SettingsPaneMemory` (`static let key = "settingsLastPane"`, `load`, `save`, `static var standard`, `static var none`). `@MainActor @Observable final class SettingsNavigation` with `var selection: SettingsPane` and `init(memory: SettingsPaneMemory)`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/SettingsPaneTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct SettingsPaneTests {
    @Test func everyOldTabHasItsPane() {
        let expected: [String: SettingsPane] = [
            "general": .general,
            "model": .model,
            "presets": .presets,
            "permissions": .permissions,
            "microphone": .microphone,
            "aiProvider": .aiProvider,
            "fileTranscription": .files,
            "recordings": .library,
            "agents": .agents,
            "about": .about,
        ]
        for (old, pane) in expected {
            #expect(SettingsPane(storedValue: old) == pane, "old tab \(old)")
        }
    }

    @Test func everyPaneRoundTrips() {
        for pane in SettingsPane.allCases {
            #expect(SettingsPane(storedValue: pane.rawValue) == pane)
        }
    }

    @Test func unknownValuesAreNil() {
        #expect(SettingsPane(storedValue: "") == nil)
        #expect(SettingsPane(storedValue: "General") == nil)
        #expect(SettingsPane(storedValue: "fileTranscriptions") == nil)
    }

    @Test func sidebarFollowsTheSpec() {
        let groups = SettingsPane.SidebarGroup.allCases.map { group in
            (group.title, group.panes.map(\.title))
        }
        #expect(groups.map(\.0) == [nil, "Transcription", "Library", nil])
        #expect(groups.map(\.1) == [
            ["General", "Presets", "Microphone"],
            ["Model", "AI Provider", "Files"],
            ["Library & Meetings", "Agents"],
            ["Permissions", "About"],
        ])
    }

    @Test func titlesHaveNoDashes() {
        for pane in SettingsPane.allCases {
            #expect(!pane.title.contains("\u{2014}") && !pane.title.contains("\u{2013}"))
        }
    }
}

@MainActor
struct SettingsNavigationTests {
    /// In-memory stand-in for the defaults.
    @MainActor
    final class Store {
        var value: String?
        var memory: SettingsPaneMemory {
            SettingsPaneMemory(load: { self.value }, save: { self.value = $0 })
        }
    }

    @Test func startsOnGeneralWithoutAStoredPane() {
        let navigation = SettingsNavigation(memory: Store().memory)
        #expect(navigation.selection == .general)
    }

    @Test func startsOnTheStoredPane() {
        let store = Store()
        store.value = "recordings"
        #expect(SettingsNavigation(memory: store.memory).selection == .library)
        store.value = "nonsense"
        #expect(SettingsNavigation(memory: store.memory).selection == .general)
    }

    @Test func remembersTheLastPane() {
        let store = Store()
        let first = SettingsNavigation(memory: store.memory)
        first.selection = .microphone
        #expect(store.value == "microphone")
        #expect(SettingsNavigation(memory: store.memory).selection == .microphone)
    }

    @Test func selectingTheSamePaneWritesNothing() {
        let store = Store()
        let navigation = SettingsNavigation(memory: store.memory)
        navigation.selection = .general
        #expect(store.value == nil)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/SettingsPaneTests -only-testing:RogerTests/SettingsNavigationTests 2>&1 | tail -20`
Expected: build fails with "cannot find 'SettingsPane' in scope".

- [ ] **Step 3: Write the implementation**

Create `Roger/UI/Settings/SettingsPane.swift`:

```swift
import SwiftUI

/// One page of the settings window, in sidebar order. The raw value is
/// stored as the last pane and names the snapshot files.
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case presets
    case microphone
    case model
    case aiProvider
    case files
    case library
    case agents
    case permissions
    case about

    /// The blocks of the sidebar, top to bottom.
    enum SidebarGroup: CaseIterable, Hashable {
        case top
        case transcription
        case library
        case bottom

        /// Section header, nil for the blocks without one.
        var title: String? {
            switch self {
            case .top, .bottom: return nil
            case .transcription: return "Transcription"
            case .library: return "Library"
            }
        }

        var panes: [SettingsPane] {
            SettingsPane.allCases.filter { $0.sidebarGroup == self }
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .presets: return "Presets"
        case .microphone: return "Microphone"
        case .model: return "Model"
        case .aiProvider: return "AI Provider"
        case .files: return "Files"
        case .library: return "Library & Meetings"
        case .agents: return "Agents"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .presets: return "text.badge.star"
        case .microphone: return "mic"
        case .model: return "waveform"
        case .aiProvider: return "sparkles"
        case .files: return "doc.text"
        case .library: return "books.vertical"
        case .agents: return "point.3.connected.trianglepath.dotted"
        case .permissions: return "hand.raised"
        case .about: return "info.circle"
        }
    }

    /// Fill of the rounded square behind the symbol.
    var color: Color {
        switch self {
        case .general: return .gray
        case .presets: return .orange
        case .microphone: return .red
        case .model: return .purple
        case .aiProvider: return .pink
        case .files: return .blue
        case .library: return .brown
        case .agents: return .teal
        case .permissions: return .indigo
        case .about: return .gray
        }
    }

    var sidebarGroup: SidebarGroup {
        switch self {
        case .general, .presets, .microphone: return .top
        case .model, .aiProvider, .files: return .transcription
        case .library, .agents: return .library
        case .permissions, .about: return .bottom
        }
    }

    /// A stored pane name. Also takes the tab names of Roger 0.25 and
    /// earlier ("fileTranscription", "recordings").
    init?(storedValue: String) {
        if let pane = SettingsPane(rawValue: storedValue) {
            self = pane
            return
        }
        switch storedValue {
        case "fileTranscription": self = .files
        case "recordings": self = .library
        default: return nil
        }
    }
}
```

Create `Roger/UI/Settings/SettingsNavigation.swift`:

```swift
import Foundation
import Observation

/// Where the last settings pane is kept between launches.
struct SettingsPaneMemory {
    static let key = "settingsLastPane"

    let load: @MainActor () -> String?
    let save: @MainActor (String) -> Void

    /// The app's own defaults.
    static var standard: SettingsPaneMemory {
        SettingsPaneMemory(
            load: { UserDefaults.standard.string(forKey: key) },
            save: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    /// Remembers nothing (snapshot runs).
    static var none: SettingsPaneMemory {
        SettingsPaneMemory(load: { nil }, save: { _ in })
    }
}

/// The selected pane of the settings window. Shared by the window
/// controller, the sidebar and panes that link to another pane.
@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsPane {
        didSet {
            if selection != oldValue { memory.save(selection.rawValue) }
        }
    }

    @ObservationIgnored private let memory: SettingsPaneMemory

    init(memory: SettingsPaneMemory) {
        self.memory = memory
        self.selection = memory.load().flatMap(SettingsPane.init(storedValue:)) ?? .general
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

Run the command of Step 2 again.
Expected: `Test run with 9 tests in 2 suites passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/UI/Settings/SettingsPane.swift Roger/UI/Settings/SettingsNavigation.swift Roger/RogerTests/SettingsPaneTests.swift Roger/Roger.xcodeproj
git commit -m "feat: add settings panes and remember the last one"
```

---

### Task 3: The settings window and every link to it

The old pane views move into the new window unchanged in this task. Their look changes in Tasks 5 to 8.

**Files:**
- Create: `Roger/App/SettingsWindowController.swift`, `Roger/UI/Settings/SettingsRootView.swift`
- Modify: `Roger/App/RogerApp.swift` (body, KeyboardShortcuts doc comments, AppDelegate), `Roger/App/AppCoordinator.swift` (after `openLibrary`), `Roger/App/AppState.swift` (remove `pendingSettingsTab`), `Roger/UI/SettingsView.swift` (remove `SettingsTab` and `SettingsView`), `Roger/UI/MenuBarView.swift` (three links, two helpers), `Roger/UI/Library/LibraryEmptyState.swift` (button)
- Test: `Roger/RogerTests/SettingsWindowControllerTests.swift`

**Interfaces:**
- Consumes: `AppWindowPresence` (Task 1), `SettingsPane`, `SettingsPaneMemory`, `SettingsNavigation` (Task 2).
- Produces: `@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate` with `static let frameName = "RogerSettingsWindow"`, `static let defaultSize = NSSize(width: 720, height: 540)`, `static let minimumSize = NSSize(width: 640, height: 460)`, `static let sidebarWidth: CGFloat = 200`, `let navigation: SettingsNavigation`, `private(set) var window: NSWindow?`, `private(set) var isOpen: Bool`, `init(presence:memory:frameAutosaveName:present:makeContent:)`, `func show(_ pane: SettingsPane? = nil)`, `static func presentOnScreen(_:)`. `struct SettingsRootView: View` (`init(navigation:)`), `struct SettingsPaneIcon`, `struct SettingsPaneContent` (`init(pane:)`). `AppCoordinator.settingsOpener: (@MainActor (SettingsPane?) -> Void)?` and `AppCoordinator.openSettings(_ pane: SettingsPane? = nil)`. `AppDelegate.showSettings(_ pane: SettingsPane? = nil)` and `private func makeSettingsWindowController(memory:frameAutosaveName:)`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/SettingsWindowControllerTests.swift`:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Roger

@MainActor
struct SettingsWindowControllerTests {
    final class Log {
        var policies: [NSApplication.ActivationPolicy] = []
        var presented = 0
    }

    private func make(_ log: Log) -> SettingsWindowController {
        let presence = AppWindowPresence { log.policies.append($0) }
        return SettingsWindowController(
            presence: presence,
            memory: .none,
            frameAutosaveName: nil,
            present: { _ in log.presented += 1 },
            makeContent: { _ in AnyView(EmptyView()) }
        )
    }

    @Test func showSelectsThePaneAndReusesTheWindow() throws {
        let log = Log()
        let controller = make(log)
        controller.show(.presets)
        let first = try #require(controller.window)
        #expect(controller.navigation.selection == .presets)
        #expect(controller.isOpen)

        controller.show(.microphone)
        #expect(controller.window === first)
        #expect(controller.navigation.selection == .microphone)
        #expect(log.presented == 2)
        #expect(log.policies == [.regular])
    }

    @Test func showWithoutAPaneKeepsTheSelection() {
        let log = Log()
        let controller = make(log)
        controller.show(.agents)
        controller.show()
        #expect(controller.navigation.selection == .agents)
    }

    @Test func closingLeavesThePresenceAndReopenReusesTheWindow() throws {
        let log = Log()
        let controller = make(log)
        controller.show(.files)
        let window = try #require(controller.window)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(!controller.isOpen)
        #expect(log.policies == [.regular, .accessory])

        controller.show()
        #expect(controller.window === window)
        #expect(controller.navigation.selection == .files)
        #expect(log.policies == [.regular, .accessory, .regular])
    }

    @Test func anotherWindowClosingIsIgnored() {
        let log = Log()
        let controller = make(log)
        controller.show(.general)
        let other = NSWindow()
        other.isReleasedWhenClosed = false
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: other))
        #expect(controller.isOpen)
        #expect(log.policies == [.regular])
    }

    @Test func theWindowHasTheSpecSizes() throws {
        let controller = make(Log())
        controller.show()
        let window = try #require(controller.window)
        #expect(window.contentMinSize == NSSize(width: 640, height: 460))
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 720, height: 540))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/SettingsWindowControllerTests 2>&1 | tail -20`
Expected: build fails with "cannot find 'SettingsWindowController' in scope".

- [ ] **Step 3: Write the window controller**

Create `Roger/App/SettingsWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Owns the settings window: an NSWindow hosting the settings sidebar and
/// panes, created once and reused. While it is open, Roger shows in the
/// Dock and in Cmd-Tab (through `AppWindowPresence`).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let frameName = "RogerSettingsWindow"
    static let defaultSize = NSSize(width: 720, height: 540)
    static let minimumSize = NSSize(width: 640, height: 460)

    let navigation: SettingsNavigation
    private let presence: AppWindowPresence
    private let frameAutosaveName: String?
    private let present: @MainActor (NSWindow) -> Void
    private let makeContent: @MainActor (SettingsNavigation) -> AnyView
    private(set) var window: NSWindow?
    /// True from `show` until the window closes (also while minimized).
    private(set) var isOpen = false

    /// `frameAutosaveName` nil keeps no frame (tests, snapshot runs).
    /// `present` puts the window on screen; tests pass a no-op.
    init(
        presence: AppWindowPresence,
        memory: SettingsPaneMemory,
        frameAutosaveName: String? = SettingsWindowController.frameName,
        present: @escaping @MainActor (NSWindow) -> Void = SettingsWindowController.presentOnScreen,
        makeContent: @escaping @MainActor (SettingsNavigation) -> AnyView
    ) {
        self.navigation = SettingsNavigation(memory: memory)
        self.presence = presence
        self.frameAutosaveName = frameAutosaveName
        self.present = present
        self.makeContent = makeContent
    }

    /// Shows the window with `pane` selected (the last pane when nil). A
    /// second call brings the same window to the front.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.selection = pane }
        let window = self.window ?? makeWindow()
        isOpen = true
        // Before the window is shown, so the Dock icon does not flash.
        presence.enter(.settings)
        if window.isMiniaturized { window.deminiaturize(nil) }
        present(window)
        widenSidebarOnce()
    }

    private var sidebarWidened = false

    /// SwiftUI starts the sidebar narrower than its column width in an
    /// AppKit window, which cuts "Library & Meetings". Set it once after the
    /// first layout; the user can still drag it.
    private func widenSidebarOnce() {
        guard !sidebarWidened, let content = window?.contentView else { return }
        sidebarWidened = true
        DispatchQueue.main.async {
            guard let split = Self.firstSplitView(in: content), split.arrangedSubviews.count > 1,
                  split.arrangedSubviews[0].frame.width < Self.sidebarWidth else { return }
            split.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        }
    }

    static let sidebarWidth: CGFloat = 200

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = firstSplitView(in: child) { return split }
        }
        return nil
    }

    static func presentOnScreen(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        // Right after the policy change the menu bar can still belong to the
        // previous app. Activating on the next run loop turn fixes that.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        isOpen = false
        presence.leave(.settings)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: makeContent(navigation))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // Keep the saved frame; do not let SwiftUI resize the window.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.title = navigation.selection.title
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.delegate = self
        window.contentMinSize = Self.minimumSize
        if let name = frameAutosaveName, window.setFrameUsingName(name) {
            window.setFrameAutosaveName(name)
        } else {
            window.setContentSize(Self.defaultSize)
            window.center()
            if let name = frameAutosaveName { window.setFrameAutosaveName(name) }
        }
        self.window = window
        return window
    }
}
```

- [ ] **Step 4: Write the root view with the old panes inside**

Create `Roger/UI/Settings/SettingsRootView.swift`. `SettingsPaneContent` points at the old views for now; Tasks 5 to 8 replace one line each.

```swift
import SwiftUI

/// The settings window: sidebar grouped like System Settings, the selected
/// pane on the right. The window title is the pane name.
struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SettingsPane.SidebarGroup.allCases, id: \.self) { group in
                    if let title = group.title {
                        Section(title) { rows(group.panes) }
                    } else {
                        Section { rows(group.panes) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPaneContent(pane: navigation.selection)
                .navigationTitle(navigation.selection.title)
        }
        .environment(navigation)
    }

    /// List selection is optional; a click on empty space keeps the pane.
    private var sidebarSelection: Binding<SettingsPane?> {
        Binding(
            get: { navigation.selection },
            set: { if let pane = $0 { navigation.selection = pane } }
        )
    }

    private func rows(_ panes: [SettingsPane]) -> some View {
        ForEach(panes) { pane in
            Label {
                Text(pane.title)
            } icon: {
                SettingsPaneIcon(pane: pane)
            }
            .tag(pane)
        }
    }
}

/// White symbol on a small rounded colored square, like System Settings.
struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .imageScale(.small)
            .frame(width: 20, height: 20)
            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The pane for a sidebar entry.
struct SettingsPaneContent: View {
    @Environment(AppCoordinator.self) private var coordinator
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralSettingsView(state: coordinator.appState)
        case .presets: PresetsSettingsView()
        case .microphone: MicrophoneSettingsView()
        case .model: ModelSettingsView()
        case .aiProvider: AIProviderSettingsView()
        case .files: FileTranscriptionSettingsView(state: coordinator.appState)
        case .library: RecordingsSettingsView()
        case .agents: AgentsSettingsView()
        case .permissions: PermissionsSettingsView()
        case .about: AboutView()
        }
    }
}
```

- [ ] **Step 5: Remove the old tab view and `pendingSettingsTab`**

In `Roger/UI/SettingsView.swift` delete everything from `enum SettingsTab: String, Hashable {` down to (not including) the line `// MARK: - General`: the `SettingsTab` enum and the `SettingsView` struct with `consumePendingTab()`. The pane structs below stay for now.

In `Roger/App/AppState.swift` delete:

```swift
    // MARK: - UI Navigation (runtime-only)

    var pendingSettingsTab: SettingsTab?

```

- [ ] **Step 6: Add `openSettings` to the coordinator**

Read `Roger/App/AppCoordinator.swift`. Right after:

```swift
    /// Opens the library window, with the item at `url` selected when given.
    func openLibrary(selecting url: URL? = nil) {
        libraryOpener?(url)
    }
```

add:

```swift

    /// Opens the settings window. Set by the AppDelegate, which owns the
    /// window; nil in unit tests.
    @ObservationIgnored var settingsOpener: (@MainActor (SettingsPane?) -> Void)?

    /// Opens the settings window on `pane`, or on the last pane when nil.
    func openSettings(_ pane: SettingsPane? = nil) {
        settingsOpener?(pane)
    }
```

- [ ] **Step 7: Scene, command and AppDelegate**

Read `Roger/App/RogerApp.swift` as part A left it. Replace the whole `var body: some Scene { ... }` of `RogerApp` (whatever part A made of it) with:

```swift
    var body: some Scene {
        // Settings live in their own window (SettingsWindowController). This
        // empty scene is never shown. It only carries the Settings command,
        // which Roger's main menu has while a window makes it a regular app.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
```

Part A's body checked `AppLaunch.isRunningTests`; the new body does not need it, but keep `AppLaunch` (`applicationDidFinishLaunching` still uses it). Part A's `AppCoordinator.instancesCreated` test keeps passing: the body above never touches `sharedCoordinator`.

In the `KeyboardShortcuts.Name` extension replace the doc comment of `meetingRecordingToggle`:

```swift
    /// Global hotkey to start/stop a meeting recording. User-configurable
    /// from the Recordings settings tab. Unset by default — Roger only takes
    /// the hotkey if the user explicitly assigns one.
```

with:

```swift
    /// Global hotkey to start/stop a meeting recording. Set in Settings >
    /// General. Unset by default, Roger only takes the hotkey if the user
    /// explicitly assigns one.
```

and in `applicationDidFinishLaunching` replace the comment `// user has assigned a key combo from the Recordings settings tab.` with `// user has assigned a key combo in Settings > General.`.

In `AppDelegate`, after `private var libraryWindowController: LibraryWindowController?` add:

```swift
    private var settingsWindowController: SettingsWindowController?
```

In `applicationDidFinishLaunching`, right after the `coordinator.libraryOpener = { ... }` assignment, add:

```swift
        coordinator.settingsOpener = { [weak self] pane in
            self?.showSettings(pane)
        }
```

Right before `private func makeLibraryIndexStore() -> LibraryIndexStore {` add:

```swift
    // MARK: - Settings

    /// Shows the settings window on `pane`, or on the last pane when nil.
    func showSettings(_ pane: SettingsPane? = nil) {
        popover?.performClose(nil)
        let controller = settingsWindowController ?? makeSettingsWindowController()
        settingsWindowController = controller
        controller.show(pane)
    }

    private func makeSettingsWindowController(
        memory: SettingsPaneMemory = .standard,
        frameAutosaveName: String? = SettingsWindowController.frameName
    ) -> SettingsWindowController {
        SettingsWindowController(
            presence: .shared,
            memory: memory,
            frameAutosaveName: frameAutosaveName,
            makeContent: { navigation in
                AnyView(SettingsRootView(navigation: navigation).environment(sharedCoordinator))
            }
        )
    }

```

Replace `applicationShouldHandleReopen` and its doc comment:

```swift
    /// Clicking the Dock icon (only there while the library is open) brings
    /// the library to the front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller = libraryWindowController, controller.isOpen {
            controller.show()
        }
        return false
    }
```

with:

```swift
    /// Clicking the Dock icon (only there while the library or the settings
    /// window is open) brings that window to the front, the library first.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller = libraryWindowController, controller.isOpen {
            controller.show()
        } else if let controller = settingsWindowController, controller.isOpen {
            controller.show()
        }
        return false
    }
```

- [ ] **Step 8: Switch the links**

In `Roger/UI/MenuBarView.swift`:

The Settings row: replace

```swift
                SettingsLink {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
```

with

```swift
                Button {
                    coordinator.openSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gear")
```

and below that row replace

```swift
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    activateSettingsWindow()
                })
```

with

```swift
                .buttonStyle(.plain)
```

The agent skill hint: replace

```swift
            SettingsLink {
                Text("Agent skill outdated - update in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                coordinator.appState.pendingSettingsTab = .agents
                activateSettingsWindow()
            })
```

with

```swift
            Button {
                coordinator.openSettings(.agents)
            } label: {
                Text("Agent skill outdated - update in Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
```

The "Edit presets" pencil: replace

```swift
                SettingsLink {
                    Image(systemName: "square.and.pencil")
```

with

```swift
                Button {
                    coordinator.openSettings(.presets)
                } label: {
                    Image(systemName: "square.and.pencil")
```

and replace

```swift
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    coordinator.appState.pendingSettingsTab = .presets
                    activateSettingsWindow()
                })
                .help("Edit presets")
```

with

```swift
                .buttonStyle(.plain)
                .help("Edit presets")
```

Delete the helpers `private func dismissPopover()` and `private func activateSettingsWindow()` at the end of `MenuBarView` (the popover is closed by `AppDelegate.showSettings`).

In `Roger/UI/Library/LibraryEmptyState.swift` (read it first, part A added a missing-root state), replace inside `LibraryEmptyStateView`:

```swift
            if state.showsPresetsButton {
                SettingsLink {
                    Text("Open Presets Settings")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    coordinator.appState.pendingSettingsTab = .presets
                })
            }
```

with

```swift
            if state.showsPresetsButton {
                Button("Open Presets Settings") {
                    coordinator.openSettings(.presets)
                }
            }
```

Check: `grep -rn "SettingsLink\|activateSettingsWindow\|pendingSettingsTab\|SettingsTab\|com_apple_SwiftUI_Settings_window\|dismissPopover" /Users/jordi/git/roger/Roger --include='*.swift'` prints nothing.

- [ ] **Step 9: Regenerate, build and run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, the 5 `SettingsWindowControllerTests` pass, no "Restarting after unexpected exit".

- [ ] **Step 10: Manual check**

Run Roger from Xcode.
- Popover > Settings: the window opens on General (first time) at 720 × 540, sidebar groups as in the spec, "Library & Meetings" not cut. Roger is in the Dock and in Cmd-Tab. The window title is the pane name.
- Cmd-, while the window is key: same window. Close it, Roger leaves the Dock. Cmd-, does nothing while Roger is a menu bar app (no main menu), as the spec says.
- Open the library, then Settings, close the library: Roger stays in the Dock. Close Settings: Roger leaves it. Repeat in the other order.
- Popover pencil > Presets pane, agent hint (if shown) > Agents pane, library Logs empty state "Open Presets Settings" > Presets pane.
- Quit and relaunch, open Settings: the last pane is selected and the frame is where you left it. Full screen is not offered (green button zooms). Minimize works, the Dock icon brings the window back.

- [ ] **Step 11: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/App/SettingsWindowController.swift Roger/UI/Settings/SettingsRootView.swift Roger/App/RogerApp.swift Roger/App/AppCoordinator.swift Roger/App/AppState.swift Roger/UI/SettingsView.swift Roger/UI/MenuBarView.swift Roger/UI/Library/LibraryEmptyState.swift Roger/RogerTests/SettingsWindowControllerTests.swift Roger/Roger.xcodeproj
git commit -m "feat: open settings in their own window with a sidebar"
```

---

### Task 4: Snapshot mode for the settings panes

**Files:**
- Create: `Roger/App/SettingsSnapshotRunner.swift`, `scripts/settings-snapshots.sh`
- Modify: `Roger/App/LibrarySnapshotRunner.swift` (`settle` and `render` lose `private`), `Roger/App/RogerApp.swift` (DEBUG start)

**Interfaces:**
- Consumes: `SettingsWindowController` (`show`, `window`, `minimumSize`), `SettingsPane.allCases`, `SettingsPaneMemory.none`, `AppDelegate.makeSettingsWindowController(memory:frameAutosaveName:)` (Task 3).
- Produces: `SettingsSnapshotRunner.isRequested`, `SettingsSnapshotRunner.run(controller:folder:)`, `SettingsSnapshotRunner.fileName(_:_:)`; `scripts/settings-snapshots.sh <folder>` (builds Debug, renders 30 PNGs, exit 1 when not 30). Every later UI task runs this script.

This is a debug tool without unit tests (the library snapshot mode has none either). Its check is the run itself: 30 files, nothing written to the settings.

- [ ] **Step 1: Share `settle` and `render`**

In `Roger/App/LibrarySnapshotRunner.swift` change `private static func settle(seconds: Double = 1) async {` to `static func settle(seconds: Double = 1) async {` and `private static func render(_ window: NSWindow, _ name: String, into folder: URL) {` to `static func render(_ window: NSWindow, _ name: String, into folder: URL) {`. Nothing else changes.

- [ ] **Step 2: Write the runner**

Create `Roger/App/SettingsSnapshotRunner.swift`:

```swift
#if DEBUG
import AppKit
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "SettingsSnapshot")

/// Debug-only dev tool: renders every settings pane into PNG files, then
/// Roger quits. Start it with
/// `Roger -RogerSnapshotDir <folder> -RogerSnapshotSettings YES`
/// (or `scripts/settings-snapshots.sh <folder>`). Per pane it writes
/// `settings-<pane>.png` (light, tall enough for the whole pane),
/// `settings-<pane>-dark.png` and `settings-<pane>-min.png` (the minimum
/// window size, to see what gets cut off). The run remembers no pane and
/// no window frame, and it changes no setting.
@MainActor
enum SettingsSnapshotRunner {
    static let tallSize = NSSize(width: 720, height: 1000)
    /// The run quits on its own after this, whatever state it is in.
    static let watchdog: TimeInterval = 150

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "RogerSnapshotSettings")
    }

    /// One image per pane and variant.
    struct Variant {
        let suffix: String
        let size: NSSize
        let appearance: NSAppearance.Name?
    }

    static let variants = [
        Variant(suffix: "", size: tallSize, appearance: .aqua),
        Variant(suffix: "-dark", size: tallSize, appearance: .darkAqua),
        Variant(suffix: "-min", size: SettingsWindowController.minimumSize, appearance: .aqua),
    ]

    static func fileName(_ pane: SettingsPane, _ variant: Variant) -> String {
        "settings-\(pane.rawValue)\(variant.suffix).png"
    }

    static func run(controller: SettingsWindowController, folder: URL) async {
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdog) {
            logger.error("Settings snapshot run did not finish in time")
            exit(2)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.error("Settings snapshot run: cannot create \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        controller.show(.general)
        guard let window = controller.window else {
            logger.error("Settings snapshot run: no settings window")
            return
        }
        window.isRestorable = false
        // The first layout of the window takes longer.
        await LibrarySnapshotRunner.settle(seconds: 2)

        for pane in SettingsPane.allCases {
            controller.show(pane)
            // Agents looks for coding agents and Claude Desktop first.
            await LibrarySnapshotRunner.settle(seconds: pane == .agents ? 5 : 1.5)
            for variant in variants {
                window.appearance = variant.appearance.flatMap(NSAppearance.init(named:))
                window.setContentSize(variant.size)
                window.center()
                await LibrarySnapshotRunner.settle(seconds: 0.8)
                LibrarySnapshotRunner.render(window, fileName(pane, variant), into: folder)
            }
        }
        window.appearance = nil
    }
}
#endif
```

- [ ] **Step 3: Start it from the AppDelegate**

In `Roger/App/RogerApp.swift`, `applicationDidFinishLaunching`, replace:

```swift
        #if DEBUG
        if let folder = LibrarySnapshotRunner.requestedFolder {
            startSnapshotRun(into: folder)
            return
        }
        #endif
```

with:

```swift
        #if DEBUG
        if let folder = LibrarySnapshotRunner.requestedFolder {
            if SettingsSnapshotRunner.isRequested {
                startSettingsSnapshotRun(into: folder)
            } else {
                startSnapshotRun(into: folder)
            }
            return
        }
        #endif
```

Inside the `#if DEBUG` block that holds `startSnapshotRun(into:)`, after that function, add:

```swift

    /// Settings snapshot mode: only the settings window, without the launch
    /// work. Remembers no pane and no window frame.
    private func startSettingsSnapshotRun(into folder: URL) {
        let controller = makeSettingsWindowController(memory: .none, frameAutosaveName: nil)
        settingsWindowController = controller
        sharedCoordinator.settingsOpener = { [weak self] pane in
            self?.showSettings(pane)
        }
        Task {
            await SettingsSnapshotRunner.run(controller: controller, folder: folder)
            NSApp.terminate(nil)
        }
    }
```

- [ ] **Step 4: Write the script**

Create `scripts/settings-snapshots.sh` and make it executable (`chmod +x scripts/settings-snapshots.sh`):

```bash
#!/usr/bin/env bash
# Builds Roger (Debug) and renders every settings pane into PNG files:
# settings-<pane>.png (light), settings-<pane>-dark.png and
# settings-<pane>-min.png (minimum window size). Roger quits on its own.
# The run changes no setting.
#
# Usage: scripts/settings-snapshots.sh <folder>
# The folder must not exist yet, or be empty.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <folder>" >&2
  exit 1
fi
out=$1
if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
  echo "error: $out is not empty" >&2
  exit 1
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo/Roger"
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build -quiet
products=$(xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / { print $2; exit }')

"$products/Roger.app/Contents/MacOS/Roger" -RogerSnapshotDir "$out" -RogerSnapshotSettings YES

count=$(find "$out" -name 'settings-*.png' | wc -l | tr -d ' ')
echo "$count images in $out"
if [ "$count" -ne 30 ]; then
  echo "error: expected 30 images" >&2
  exit 1
fi
```

- [ ] **Step 5: Regenerate, build and run it**

Run:

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
defaults read com.jordiboehme.roger settingsLastPane 2>&1 | tail -1 > /tmp/roger-pane-before.txt
cd /Users/jordi/git/roger && scripts/settings-snapshots.sh /tmp/roger-settings-task4
defaults read com.jordiboehme.roger settingsLastPane 2>&1 | tail -1 | diff - /tmp/roger-pane-before.txt && echo "pane unchanged"
ls /tmp/roger-settings-task4
```

Expected: `30 images in /tmp/roger-settings-task4`, `pane unchanged`, and the list `settings-about.png ... settings-permissions-min.png` (10 panes × 3). If `/tmp/roger-settings-task4` exists from an earlier run, pick a new folder name.

- [ ] **Step 6: Look at the images**

Open `settings-general.png`, `settings-library-min.png` and `settings-agents-dark.png` (Read tool). Expected: the title bar shows the pane name, the sidebar has the four groups with colored icons, "Library & Meetings" is not cut, the dark image is dark. The panes still show the old card look (changed from Task 5 on). If the selected sidebar row renders as a black bar without text, that is a render artifact of `cacheDisplay` for the emphasized selection, not the real look; note it in the report and compare once on screen.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/App/SettingsSnapshotRunner.swift Roger/App/LibrarySnapshotRunner.swift Roger/App/RogerApp.swift scripts/settings-snapshots.sh Roger/Roger.xcodeproj
git commit -m "chore: add a debug snapshot mode for the settings panes"
```

---

### Task 5: Shared kit, General and Permissions

**Files:**
- Create: `Roger/UI/Settings/SettingsKit.swift`, `Roger/UI/Settings/SettingsFormat.swift`, `Roger/Services/CapsLockRemap.swift`, `Roger/UI/Settings/GeneralPane.swift`, `Roger/UI/Settings/PermissionsPane.swift`
- Modify: `Roger/App/AppState.swift` (`ActivationMode`), `Roger/UI/Settings/SettingsRootView.swift` (two cases), `Roger/UI/SettingsView.swift` (delete `GeneralSettingsView` and `PermissionsSettingsView`)
- Test: `Roger/RogerTests/CapsLockRemapTests.swift`, `Roger/RogerTests/GeneralSettingsTests.swift`

**Interfaces:**
- Consumes: `SettingsNavigation` from the environment (Task 3 puts it there), `KeyboardShortcuts.Name.meetingRecordingToggle` and `.openLibrary`, `HotkeyManager.remapCapsLockToF18()`, `HotkeyManager.installRemapLaunchAgent()`.
- Produces (kit, used by every later pane): `SettingsForm { ... }`; `SettingsLabel(title:note:noteColor:truncatesNote:)`; `SettingsRow(title:note:noteColor:truncatesNote:) { control }`; `SettingsToggle(title:note:isOn:)`; `SettingsBanner(symbol:tint:message:actionTitle:action:)`; `SettingsStatus(level: .good | .warning | .bad | .unknown, text:)`; `SettingsDurationStepper(seconds:range:step:)`; `SettingsResultColor.color(for: String?) -> Color` (green for "OK...", red otherwise, secondary for nil); `SettingsShortcutRecorder(name:)`; `SettingsFormat.duration(_:locale:) -> String`. Also `CapsLockRemap.isActive(hidutilOutput:) -> Bool`, `CapsLockRemap.isActiveNow() async -> Bool`, `ActivationMode.title`, `ActivationMode.note`, `GeneralPane.missingPermissionsMessage(microphone:accessibility:) -> String?`, `GeneralPane.dictationKey(capsLockActive:)`, `GeneralPane.dictationNote(capsLockActive:)`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/CapsLockRemapTests.swift`:

```swift
import Testing
@testable import Roger

struct CapsLockRemapTests {
    static let realOutput = """
    RegistryID  Key                   Value
    1000009bb   UserKeyMapping   (
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    10000082d   UserKeyMapping   (
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771129;
        }
    )
    """

    @Test func findsTheMappingInRealOutput() {
        #expect(CapsLockRemap.isActive(hidutilOutput: Self.realOutput))
    }

    @Test func emptyMappingIsOff() {
        #expect(!CapsLockRemap.isActive(hidutilOutput: "RegistryID  Key  Value\n1000009bb   UserKeyMapping   (\n)\n"))
        #expect(!CapsLockRemap.isActive(hidutilOutput: "(null)"))
        #expect(!CapsLockRemap.isActive(hidutilOutput: ""))
    }

    @Test func otherMappingsDoNotCount() {
        let swapped = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771129;
            HIDKeyboardModifierMappingSrc = 30064771181;
        }
        )
        """
        #expect(!CapsLockRemap.isActive(hidutilOutput: swapped))
        let split = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771300;
            HIDKeyboardModifierMappingSrc = 30064771129;
        },
            {
            HIDKeyboardModifierMappingDst = 30064771181;
            HIDKeyboardModifierMappingSrc = 30064771300;
        }
        )
        """
        #expect(!CapsLockRemap.isActive(hidutilOutput: split))
    }

    @Test func findsItAmongOtherMappingsAndInHex() {
        let mixed = """
        (
            {
            HIDKeyboardModifierMappingDst = 30064771300;
            HIDKeyboardModifierMappingSrc = 30064771299;
        },
            {
            HIDKeyboardModifierMappingSrc = 0x700000039;
            HIDKeyboardModifierMappingDst = 0x70000006D;
        }
        )
        """
        #expect(CapsLockRemap.isActive(hidutilOutput: mixed))
    }

    @Test func usagesMatchTheRemapCommand() {
        #expect(CapsLockRemap.capsLockUsage == 30_064_771_129)
        #expect(CapsLockRemap.f18Usage == 30_064_771_181)
    }
}
```

Create `Roger/RogerTests/GeneralSettingsTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct SettingsFormatTests {
    let english = Locale(identifier: "en_US")

    @Test func secondsAndMinutes() {
        #expect(SettingsFormat.duration(1.5, locale: english) == "1.5 s")
        #expect(SettingsFormat.duration(2, locale: english) == "2 s")
        #expect(SettingsFormat.duration(0, locale: english) == "0 s")
        #expect(SettingsFormat.duration(30, locale: english) == "30 s")
        #expect(SettingsFormat.duration(60, locale: english) == "1 min")
        #expect(SettingsFormat.duration(90, locale: english) == "1 min 30 s")
        #expect(SettingsFormat.duration(600, locale: english) == "10 min")
    }

    @Test func germanUsesAComma() {
        #expect(SettingsFormat.duration(1.5, locale: Locale(identifier: "de_DE")) == "1,5 s")
    }
}

@MainActor
struct GeneralPaneTextTests {
    @Test func bannerNamesWhatIsMissing() {
        #expect(GeneralPane.missingPermissionsMessage(microphone: true, accessibility: true) == nil)
        #expect(GeneralPane.missingPermissionsMessage(microphone: false, accessibility: true)
            == "Roger needs access to the microphone to hear you.")
        #expect(GeneralPane.missingPermissionsMessage(microphone: true, accessibility: false)
            == "Roger needs Accessibility access to type your text and to see the dictation key.")
        #expect(GeneralPane.missingPermissionsMessage(microphone: false, accessibility: false)
            == "Roger needs access to the microphone and Accessibility access.")
    }

    @Test func dictationKeyFollowsTheRemap() {
        #expect(GeneralPane.dictationKey(capsLockActive: true) == "Caps Lock")
        #expect(GeneralPane.dictationKey(capsLockActive: false) == "F18")
        #expect(GeneralPane.dictationKey(capsLockActive: nil) == "Caps Lock or F18")
        #expect(GeneralPane.dictationNote(capsLockActive: false).contains("not set up"))
    }

    @Test func modesHaveShortTitlesAndNotes() {
        #expect(ActivationMode.allCases.map(\.title) == ["Push to talk", "Toggle"])
        for mode in ActivationMode.allCases {
            #expect(!mode.note.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/CapsLockRemapTests -only-testing:RogerTests/SettingsFormatTests -only-testing:RogerTests/GeneralPaneTextTests 2>&1 | tail -20`
Expected: build fails with "cannot find 'CapsLockRemap' in scope".

- [ ] **Step 3: Write `CapsLockRemap`**

Create `Roger/Services/CapsLockRemap.swift`:

```swift
import Foundation

/// Whether Caps Lock sends F18 (Roger's dictation key) through a hidutil
/// key mapping. `HotkeyManager.remapCapsLockToF18()` sets that mapping.
enum CapsLockRemap {
    /// HID usages of Caps Lock (0x700000039) and F18 (0x70000006D).
    static let capsLockUsage: UInt64 = 0x7_0000_0039
    static let f18Usage: UInt64 = 0x7_0000_006D

    /// True when the output of `hidutil property --get UserKeyMapping` has a
    /// mapping from Caps Lock to F18. hidutil prints one block per keyboard
    /// with the numbers in decimal; hex is accepted too.
    static func isActive(hidutilOutput: String) -> Bool {
        let compact = String(hidutilOutput.filter { !$0.isWhitespace }).lowercased()
        let sources = ["hidkeyboardmodifiermappingsrc=\(capsLockUsage);", "hidkeyboardmodifiermappingsrc=0x700000039;"]
        let targets = ["hidkeyboardmodifiermappingdst=\(f18Usage);", "hidkeyboardmodifiermappingdst=0x70000006d;"]
        return compact.split(separator: "}").contains { block in
            sources.contains { block.contains($0) } && targets.contains { block.contains($0) }
        }
    }

    /// Asks hidutil, off the main actor. False when hidutil cannot run.
    static func isActiveNow() async -> Bool {
        await Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            task.arguments = ["property", "--get", "UserKeyMapping"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                return false
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return isActive(hidutilOutput: String(decoding: data, as: UTF8.self))
        }.value
    }
}
```

- [ ] **Step 4: Write the kit**

Create `Roger/UI/Settings/SettingsFormat.swift`:

```swift
import Foundation

/// Text for values shown in settings rows.
enum SettingsFormat {
    /// "1.5 s", "30 s", "1 min", "1 min 30 s", "10 min".
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        if seconds < 60 {
            let number = seconds.formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
            return "\(number) s"
        }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}
```

Create `Roger/UI/Settings/SettingsKit.swift`:

```swift
import KeyboardShortcuts
import SwiftUI

/// Every settings pane is one of these: a grouped form with the standard
/// margins, section headers and footers.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

/// Row title with an optional note under it.
struct SettingsLabel: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = .secondary
    /// Paths: one line, cut in the middle, full text as a tooltip.
    var truncatesNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let note {
                if truncatesNote {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(noteColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(note)
                } else {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(noteColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Label and note on the leading side, a control on the trailing side.
struct SettingsRow<Control: View>: View {
    let title: String
    var note: String? = nil
    var noteColor: Color = .secondary
    var truncatesNote = false
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            SettingsLabel(title: title, note: note, noteColor: noteColor, truncatesNote: truncatesNote)
        }
    }
}

/// A switch row with an optional note.
struct SettingsToggle: View {
    let title: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsLabel(title: title, note: note)
        }
        .toggleStyle(.switch)
    }
}

/// A notice at the top of a pane: symbol, message and one action.
struct SettingsBanner: View {
    let symbol: String
    let tint: Color
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.large)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
        }
    }
}

/// A colored dot with a short status text.
struct SettingsStatus: View {
    enum Level {
        case good
        case warning
        case bad
        case unknown

        var color: Color {
            switch self {
            case .good: return .green
            case .warning: return .orange
            case .bad: return .red
            case .unknown: return .gray
            }
        }
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// A duration with its unit and a stepper.
struct SettingsDurationStepper: View {
    @Binding var seconds: TimeInterval
    let range: ClosedRange<TimeInterval>
    let step: TimeInterval

    var body: some View {
        Stepper(value: $seconds, in: range, step: step) {
            Text(SettingsFormat.duration(seconds))
                .monospacedDigit()
        }
    }
}

/// Note color for a test result: green for "OK...", red otherwise.
enum SettingsResultColor {
    static func color(for result: String?) -> Color {
        guard let result else { return .secondary }
        return result.hasPrefix("OK") ? .green : .red
    }
}

/// A global shortcut recorder. F18 is refused: it is the dictation key.
struct SettingsShortcutRecorder: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        KeyboardShortcuts.Recorder(for: name)
            .shortcutValidation { shortcut in
                if shortcut.key == .f18 {
                    return .disallow(reason: "F18 is Roger's dictation hotkey (Caps Lock).")
                }
                return .allow
            }
    }
}
```

- [ ] **Step 5: Short mode names**

In `Roger/App/AppState.swift` replace the whole `enum ActivationMode` (at the end of the file) with:

```swift
enum ActivationMode: String, CaseIterable, Identifiable, Codable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    /// Segment title in Settings > General.
    var title: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .toggle: return "Toggle"
        }
    }

    /// Note under the Mode row.
    var note: String {
        switch self {
        case .pushToTalk: return "Hold the dictation key while you speak."
        case .toggle: return "Press the dictation key to start. Press it again to stop."
        }
    }
}
```

`displayName` goes away; its only user was the old General tab (`grep -rn "displayName" Roger --include='*.swift' | grep -i activation` must print nothing).

- [ ] **Step 6: Write the General pane**

Create `Roger/UI/Settings/GeneralPane.swift`:

```swift
import KeyboardShortcuts
import SwiftUI

/// Settings > General: how dictation starts and stops, the shortcuts, text
/// insertion and startup.
struct GeneralPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(SettingsNavigation.self) private var navigation
    /// nil while hidutil is asked.
    @State private var capsLockActive: Bool?

    var body: some View {
        @Bindable var state = coordinator.appState
        let permissions = coordinator.permissionManager
        SettingsForm {
            if let message = Self.missingPermissionsMessage(
                microphone: permissions.microphoneAuthorized,
                accessibility: permissions.accessibilityAuthorized
            ) {
                Section {
                    SettingsBanner(
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange,
                        message: message,
                        actionTitle: "Open Permissions"
                    ) {
                        navigation.selection = .permissions
                    }
                }
            }

            Section("Activation") {
                SettingsRow(title: "Mode", note: state.activationMode.note) {
                    Picker("Mode", selection: $state.activationMode) {
                        ForEach(ActivationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Minimum recording", note: "Shorter recordings are ignored, so a quick tap types nothing.") {
                    SettingsDurationStepper(seconds: $state.minimumRecordingDuration, range: 0 ... 10, step: 0.5)
                }
                SettingsRow(title: "Maximum recording", note: "Roger stops listening after this time.") {
                    SettingsDurationStepper(seconds: $state.maximumRecordingDuration, range: 30 ... 600, step: 30)
                }
            }

            Section("Shortcuts") {
                SettingsRow(title: "Dictation", note: Self.dictationNote(capsLockActive: capsLockActive)) {
                    HStack {
                        Text(Self.dictationKey(capsLockActive: capsLockActive))
                            .foregroundStyle(.secondary)
                        if capsLockActive == false {
                            Button("Set Up Caps Lock") { navigation.selection = .permissions }
                        }
                    }
                }
                SettingsRow(title: "Record a meeting", note: "Starts and stops a meeting recording.") {
                    SettingsShortcutRecorder(name: .meetingRecordingToggle)
                }
                SettingsRow(title: "Open the library") {
                    SettingsShortcutRecorder(name: .openLibrary)
                }
            }

            Section("Text insertion") {
                SettingsToggle(
                    title: "Restore the clipboard",
                    note: "When Roger has to paste the text, it puts your clipboard back afterwards.",
                    isOn: $state.restoreClipboard
                )
            }

            Section("Startup") {
                SettingsToggle(title: "Launch at login", isOn: $state.launchAtLogin)
            }
        }
        .onAppear {
            state.syncLaunchAtLogin()
            permissions.checkPermissions()
        }
        .task { capsLockActive = await CapsLockRemap.isActiveNow() }
        .onChange(of: state.activationMode) { _, newMode in
            coordinator.hotkeyManager.activationMode = newMode
        }
    }

    /// Banner text when Roger misses a permission it needs, nil otherwise.
    static func missingPermissionsMessage(microphone: Bool, accessibility: Bool) -> String? {
        switch (microphone, accessibility) {
        case (true, true): return nil
        case (false, false): return "Roger needs access to the microphone and Accessibility access."
        case (false, true): return "Roger needs access to the microphone to hear you."
        case (true, false): return "Roger needs Accessibility access to type your text and to see the dictation key."
        }
    }

    static func dictationKey(capsLockActive: Bool?) -> String {
        switch capsLockActive {
        case true?: return "Caps Lock"
        case false?: return "F18"
        case nil: return "Caps Lock or F18"
        }
    }

    static func dictationNote(capsLockActive: Bool?) -> String {
        switch capsLockActive {
        case true?: return "Caps Lock sends F18, Roger's dictation key."
        case false?: return "Caps Lock is not set up. Press F18 or set up Caps Lock."
        case nil: return "Roger listens for F18. Caps Lock sends F18 once it is set up."
        }
    }
}
```

- [ ] **Step 7: Write the Permissions pane**

Create `Roger/UI/Settings/PermissionsPane.swift` (the test and system-settings helpers are the old ones from `PermissionsSettingsView`, moved as they are):

```swift
import ApplicationServices
import SwiftUI

/// Settings > Permissions: one row per permission with its status, a fix
/// and a test.
struct PermissionsPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var micTestResult: String?
    @State private var accessibilityTestResult: String?
    @State private var hotkeyTestResult: String?
    @State private var hotkeyTestActive = false
    @State private var systemAudioTestResult: String?
    @State private var systemAudioTestRunning = false
    /// nil while hidutil is asked.
    @State private var capsLockActive: Bool?

    var body: some View {
        let pm = coordinator.permissionManager
        SettingsForm {
            Section {
                SettingsRow(
                    title: "Microphone",
                    note: micTestResult ?? "Roger hears your voice to transcribe it.",
                    noteColor: SettingsResultColor.color(for: micTestResult)
                ) {
                    HStack {
                        grantedStatus(pm.microphoneAuthorized)
                        if pm.microphoneAuthorized {
                            Button("Test") { testMicrophone() }
                        } else {
                            Button("Grant Access") {
                                Task {
                                    _ = await pm.requestMicrophone()
                                    if pm.microphoneAuthorized {
                                        await coordinator.warmUpMicrophone()
                                    }
                                }
                            }
                        }
                    }
                }

                SettingsRow(
                    title: "Accessibility",
                    note: accessibilityTestResult ?? "Roger types your text at the cursor and sees the dictation key.",
                    noteColor: SettingsResultColor.color(for: accessibilityTestResult)
                ) {
                    HStack {
                        grantedStatus(pm.accessibilityAuthorized)
                        if !pm.accessibilityAuthorized {
                            Button("Open System Settings") { pm.openAccessibilitySettings() }
                        }
                        Button("Test") { testAccessibility() }
                    }
                }
                if !pm.accessibilityAuthorized {
                    SettingsRow(
                        title: "Still not allowed?",
                        note: "Debug builds change the code signature. Remove old Roger entries in System Settings, then ask again."
                    ) {
                        Button("Reset and Ask Again") { resetAccessibility() }
                    }
                }

                SettingsRow(
                    title: "System audio",
                    note: systemAudioTestResult ?? "Roger records what the other side says in a meeting. macOS asks the first time you record, not before.",
                    noteColor: SettingsResultColor.color(for: systemAudioTestResult)
                ) {
                    HStack {
                        SettingsStatus(level: .unknown, text: "Not known")
                        Button("Open System Settings") { openAudioCapturePane() }
                        if systemAudioTestRunning {
                            ProgressView().controlSize(.small)
                        }
                        Button(systemAudioTestRunning ? "Testing…" : "Test") {
                            Task { await testSystemAudio() }
                        }
                        .disabled(systemAudioTestRunning)
                    }
                }
            } header: {
                Text("Access")
            }

            Section {
                SettingsRow(
                    title: "Dictation key",
                    note: hotkeyTestResult ?? "Roger listens for F18. Press Test, then the key.",
                    noteColor: SettingsResultColor.color(for: hotkeyTestResult)
                ) {
                    HStack {
                        SettingsStatus(
                            level: coordinator.hotkeyActive ? .good : .bad,
                            text: coordinator.hotkeyActive ? "Active" : "Not active"
                        )
                        if !coordinator.hotkeyActive {
                            Button("Retry") { coordinator.startHotkey() }
                        }
                        if hotkeyTestActive {
                            ProgressView().controlSize(.small)
                        }
                        Button(hotkeyTestActive ? "Listening…" : "Test") { testHotkey() }
                            .disabled(hotkeyTestActive)
                    }
                }
                SettingsRow(
                    title: "Caps Lock",
                    note: "Makes Caps Lock send F18. Keep at Login sets it up again after every restart."
                ) {
                    HStack {
                        SettingsStatus(
                            level: capsLockActive == true ? .good : (capsLockActive == false ? .bad : .unknown),
                            text: capsLockActive == true ? "Sends F18" : (capsLockActive == false ? "Not set up" : "Checking")
                        )
                        Button("Turn On") {
                            HotkeyManager.remapCapsLockToF18()
                            Task { capsLockActive = await CapsLockRemap.isActiveNow() }
                        }
                        Button("Keep at Login") {
                            try? HotkeyManager.installRemapLaunchAgent()
                        }
                    }
                }
            } header: {
                Text("Dictation key")
            }
        }
        .onAppear { pm.checkPermissions() }
        .task { capsLockActive = await CapsLockRemap.isActiveNow() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            pm.checkPermissions()
        }
    }

    private func grantedStatus(_ granted: Bool) -> some View {
        SettingsStatus(level: granted ? .good : .bad, text: granted ? "Allowed" : "Not allowed")
    }

    // MARK: - Actions

    /// Deep-links to System Settings › Privacy & Security › Audio. Falls back
    /// to the Privacy & Security root if the specific anchor is unknown to
    /// the current macOS build.
    private func openAudioCapturePane() {
        let anchors = [
            "com.apple.preference.security?Privacy_AudioCapture",
            "com.apple.preference.security?Privacy_Audio",
            "com.apple.preference.security"
        ]
        for anchor in anchors {
            if let url = URL(string: "x-apple.systempreferences:\(anchor)"),
               NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @MainActor
    private func testSystemAudio() async {
        systemAudioTestResult = nil
        systemAudioTestRunning = true
        defer { systemAudioTestRunning = false }

        let tap = SystemAudioTap()
        do {
            let stream = try tap.startStreaming()

            // Give the IOProc a beat to actually start delivering buffers,
            // then play a short system sound from a child process. The tap
            // excludes Roger's own PID so an in-process AVAudioPlayer would
            // be invisible by design. afplay's separate PID routes through
            // the global mix normally and IS captured.
            try? await Task.sleep(nanoseconds: 150_000_000)

            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["-v", "0.6", "/System/Library/Sounds/Funk.aiff"]
            try? player.run()

            // Wall-clock timeout. If the user denied audio-capture permission,
            // the tap returns successfully but yields no buffers. The only
            // way we learn that is by waiting and seeing nothing arrive.
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                tap.stop()
            }

            var sawAudio = false
            for await wrapper in stream {
                if let channel = wrapper.buffer.floatChannelData?[0] {
                    let frames = Int(wrapper.buffer.frameLength)
                    var peak: Float = 0
                    for i in 0 ..< frames {
                        let v = abs(channel[i])
                        if v > peak { peak = v }
                    }
                    // Threshold is well above mic-bleed but below any audible
                    // playback. Funk.aiff peaks at 0.5+ at volume 0.6.
                    if peak > 0.01 {
                        sawAudio = true
                        break
                    }
                }
            }
            timeout.cancel()
            tap.stop()
            if player.isRunning { player.terminate() }

            systemAudioTestResult = sawAudio
                ? "OK: captured system playback"
                : "No audio captured. Grant permission in System Settings › Privacy & Security › Audio."
        } catch {
            tap.stop()
            systemAudioTestResult = "Failed: \(error.localizedDescription)"
        }
    }

    private func testMicrophone() {
        micTestResult = nil
        let service = coordinator.audioCaptureService
        Task {
            do {
                let result = try await service.probe()
                if let samples = result.samples, !samples.isEmpty {
                    let peak = samples.map { abs($0) }.max() ?? 0
                    micTestResult = "OK: \(samples.count) samples (peak: \(String(format: "%.3f", peak)))"
                } else if result.health == .halStarved {
                    micTestResult = "Failed - \(AudioCaptureService.halStarvedAdvice)"
                } else {
                    micTestResult = "Failed: no audio captured"
                }
            } catch {
                micTestResult = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func resetAccessibility() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", "com.jordiboehme.roger"]
        try? task.run()
        task.waitUntilExit()
        coordinator.permissionManager.requestAccessibility()
    }

    private func testAccessibility() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        accessibilityTestResult = result == .success
            ? "OK: can read focused UI element"
            : "Failed: error \(result.rawValue)"
    }

    private func testHotkey() {
        hotkeyTestResult = nil
        hotkeyTestActive = true

        let originalStart = coordinator.hotkeyManager.onRecordingStarted
        let originalStop = coordinator.hotkeyManager.onRecordingStopped

        coordinator.hotkeyManager.onRecordingStarted = { [self] _ in
            Task { @MainActor in
                hotkeyTestResult = "OK: keypress detected!"
                hotkeyTestActive = false
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
        coordinator.hotkeyManager.onRecordingStopped = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if hotkeyTestActive {
                hotkeyTestResult = "Timeout: no keypress in 10s"
                hotkeyTestActive = false
                coordinator.hotkeyManager.onRecordingStarted = originalStart
                coordinator.hotkeyManager.onRecordingStopped = originalStop
            }
        }
    }
}
```

- [ ] **Step 8: Swap the panes and delete the old ones**

In `Roger/UI/Settings/SettingsRootView.swift`, `SettingsPaneContent`: `case .general: GeneralSettingsView(state: coordinator.appState)` becomes `case .general: GeneralPane()` and `case .permissions: PermissionsSettingsView()` becomes `case .permissions: PermissionsPane()`.

In `Roger/UI/SettingsView.swift` delete everything from `// MARK: - General` down to (not including) `// MARK: - File Transcription`: `GeneralSettingsView` and `PermissionsSettingsView` with their card helpers.

- [ ] **Step 9: Regenerate and run all tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, no "Restarting after unexpected exit".

- [ ] **Step 10: Snapshots**

Run: `cd /Users/jordi/git/roger && scripts/settings-snapshots.sh /tmp/roger-settings-task5`
Expected: `30 images`. Open `settings-general.png`, `settings-general-min.png`, `settings-general-dark.png`, `settings-permissions.png` and `settings-permissions-min.png`. Expected look: the banner on top (the Debug build has no permissions), sections Activation (segmented Push to talk / Toggle, two steppers with "1.5 s" and "2 min" or the stored values), Shortcuts (Dictation key text, two recorders), Text insertion, Startup, each row with its grey note. Permissions: Access and Dictation key sections, a colored dot with text and buttons on each row, nothing cut at the minimum size except long notes wrapping.

- [ ] **Step 11: Manual check**

Run Roger from Xcode with Accessibility and Microphone allowed. General: no banner. Mode switch changes push-to-talk/toggle behavior at once (the hotkey manager follows). Steppers change the values; quit and relaunch, they stay. Recorders refuse F18. Launch at login switch matches System Settings > General > Login Items. Turn off the Caps Lock remap in Terminal (`hidutil property --set '{"UserKeyMapping":[]}'`), reopen General: Dictation shows F18 and "Set Up Caps Lock", which opens Permissions; "Turn On" there turns the status to "Sends F18". Permissions: every Test button works as before.

- [ ] **Step 12: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/UI/Settings/SettingsKit.swift Roger/UI/Settings/SettingsFormat.swift Roger/Services/CapsLockRemap.swift Roger/UI/Settings/GeneralPane.swift Roger/UI/Settings/PermissionsPane.swift Roger/UI/Settings/SettingsRootView.swift Roger/UI/SettingsView.swift Roger/App/AppState.swift Roger/RogerTests/CapsLockRemapTests.swift Roger/RogerTests/GeneralSettingsTests.swift Roger/Roger.xcodeproj
git commit -m "feat: shared settings kit with new General and Permissions panes"
```

---

### Task 6: Presets

**Files:**
- Create: `Roger/Models/PresetEditing.swift`, `Roger/UI/Settings/PresetsPane.swift`
- Modify: `Roger/UI/Settings/SettingsRootView.swift` (one case), `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (one comment)
- Delete: `Roger/UI/PresetsSettingsView.swift`
- Test: `Roger/RogerTests/PresetEditingTests.swift`

**Interfaces:**
- Consumes: kit from Task 5 (`SettingsForm`, `SettingsLabel`, `SettingsRow`, `SettingsToggle`), `AppState.presets`, `activePresetID`, `removePreset(id:)`, `modifier(for:)`, `bindModifier(_:to:)`, `clearBinding(for:)`, `KeyComboBadge(modifier:)`, `WhisperLanguage.all`, `AppleIntelligenceLanguageSupport.supports(languageCode:)`.
- Produces: `extension DictationPreset` with `original: DictationPreset?`, `resetToOriginal() -> DictationPreset`, `isChangedBuiltIn: Bool`, `duplicated(id: UUID = UUID()) -> DictationPreset`, `static newCustom(id: UUID = UUID()) -> DictationPreset`, `dictionarySummary: String`. `struct PresetsPane: View` with `static let listWidth: CGFloat = 180` and `static func languageWarning(preset:provider:) -> String?`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/PresetEditingTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct PresetEditingTests {
    @Test func resetBringsBackTheShippedPreset() {
        var preset = DictationPreset.polished
        preset.name = "Mine"
        preset.language = "de"
        preset.enableRewrite = true
        preset.aiPrompt = "x"
        preset.output = .logEntry
        preset.dictionaryEntries = [DictionaryEntry(find: "roger", replace: "Roger")]
        #expect(preset.isChangedBuiltIn)
        let reset = preset.resetToOriginal()
        #expect(reset == DictationPreset.polished)
        #expect(!reset.isChangedBuiltIn)
    }

    @Test func resetKeepsTheRotationChoice() {
        var preset = DictationPreset.log
        preset.excludedFromRotation = false
        #expect(!preset.isChangedBuiltIn)
        preset.keepAudio = true
        let reset = preset.resetToOriginal()
        #expect(reset.keepAudio == false)
        #expect(reset.excludedFromRotation == false)
        #expect(reset.id == DictationPreset.log.id)
    }

    @Test func customPresetsHaveNoOriginal() {
        let custom = DictationPreset.newCustom()
        #expect(custom.original == nil)
        #expect(!custom.isChangedBuiltIn)
        #expect(custom.resetToOriginal() == custom)
        #expect(!custom.isBuiltIn)
    }

    @Test func duplicateIsACustomCopy() {
        let copy = DictationPreset.code.duplicated()
        #expect(copy.id != DictationPreset.code.id)
        #expect(copy.name == "Code Copy")
        #expect(!copy.isBuiltIn)
        #expect(copy.aiPrompt == DictationPreset.code.aiPrompt)
        #expect(copy.original == nil)
    }

    @Test func dictionarySummaryCountsWords() {
        var preset = DictationPreset.newCustom()
        #expect(preset.dictionarySummary == "No words")
        preset.dictionaryEntries = [DictionaryEntry(find: "a", replace: "b")]
        #expect(preset.dictionarySummary == "1 word")
        preset.dictionaryEntries.append(DictionaryEntry(find: "c", replace: "d"))
        #expect(preset.dictionarySummary == "2 words")
    }
}

@MainActor
struct PresetLanguageWarningTests {
    @Test func noWarningWithoutAPinOrWithoutAI() {
        var preset = DictationPreset.polished
        #expect(PresetsPane.languageWarning(preset: preset, provider: .appleIntelligence) == nil)
        preset.language = "en"
        #expect(PresetsPane.languageWarning(preset: preset, provider: .appleIntelligence) == nil)
        var plain = DictationPreset.plain
        plain.language = "fi"
        #expect(PresetsPane.languageWarning(preset: plain, provider: .appleIntelligence) == nil)
        var cloud = DictationPreset.polished
        cloud.language = "fi"
        #expect(PresetsPane.languageWarning(preset: cloud, provider: .claude) == nil)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/PresetEditingTests -only-testing:RogerTests/PresetLanguageWarningTests 2>&1 | tail -20`
Expected: build fails with "value of type 'DictationPreset' has no member 'isChangedBuiltIn'".

- [ ] **Step 3: Write the preset helpers**

Create `Roger/Models/PresetEditing.swift`:

```swift
import Foundation

extension DictationPreset {
    /// The shipped version of a built-in preset, nil for a custom preset.
    var original: DictationPreset? {
        DictationPreset.builtInPresets.first { $0.id == id }
    }

    /// A built-in preset brought back to its shipped version. Keeps the id
    /// and whether it is hidden from the Caps Lock rotation (that is set in
    /// the preset list, not in the preset). A custom preset stays as it is.
    func resetToOriginal() -> DictationPreset {
        guard var copy = original else { return self }
        copy.excludedFromRotation = excludedFromRotation
        return copy
    }

    /// True for a built-in preset that differs from its shipped version.
    var isChangedBuiltIn: Bool {
        original != nil && resetToOriginal() != self
    }

    /// A custom copy with a new id, named "<name> Copy".
    func duplicated(id: UUID = UUID()) -> DictationPreset {
        var copy = self
        copy.id = id
        copy.name = "\(name) Copy"
        copy.isBuiltIn = false
        return copy
    }

    /// The preset "+ New Preset" adds.
    static func newCustom(id: UUID = UUID()) -> DictationPreset {
        DictationPreset(
            id: id,
            name: "Custom",
            isBuiltIn: false,
            enableFillerRemoval: true,
            enableDedup: true,
            enableAIFormatting: true,
            enableCustomDictionary: false,
            enableRewrite: false,
            aiPrompt: "Add proper punctuation and capitalization to this dictated text. Return only the corrected text, nothing else.",
            rewritePrompt: "",
            dictionaryEntries: []
        )
    }

    /// "No words", "1 word", "3 words".
    var dictionarySummary: String {
        switch dictionaryEntries.count {
        case 0: return "No words"
        case 1: return "1 word"
        case let count: return "\(count) words"
        }
    }
}
```

- [ ] **Step 4: Write the Presets pane**

Create `Roger/UI/Settings/PresetsPane.swift`. The detail binds the preset by id (`binding(for:fallback:)`), never by array index, so deleting or resetting a preset never writes into another one.

```swift
import SwiftUI

/// Settings > Presets: the preset list on the leading side, the selected
/// preset on the trailing side.
struct PresetsPane: View {
    /// The only fixed width in a pane (spec).
    static let listWidth: CGFloat = 180

    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedPresetID: UUID?
    @State private var pendingDelete: DictationPreset?
    @State private var pendingReset: DictationPreset?

    var body: some View {
        HStack(spacing: 0) {
            presetList
                .frame(width: Self.listWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedPresetID == nil {
                selectedPresetID = coordinator.appState.activePresetID
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { preset in
            Button("Delete", role: .destructive) { delete(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You cannot undo this.")
        }
        .confirmationDialog(
            "Reset \"\(pendingReset?.name ?? "")\"?",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            presenting: pendingReset
        ) { preset in
            Button("Reset", role: .destructive) { reset(preset) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The preset gets its original steps, prompts and settings back. Your changes and dictionary words in it are lost.")
        }
    }

    // MARK: - List

    private var presetList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedPresetID) {
                ForEach(coordinator.appState.presets) { preset in
                    PresetListRow(
                        preset: preset,
                        isMain: preset.id == coordinator.appState.activePresetID,
                        modifier: coordinator.appState.modifier(for: preset.id)
                    )
                    .tag(preset.id)
                    .contextMenu { contextMenu(for: preset) }
                }
            }
            Divider()
            Button {
                addPreset()
            } label: {
                Label("New Preset", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func contextMenu(for preset: DictationPreset) -> some View {
        let state = coordinator.appState
        let isMain = preset.id == state.activePresetID
        let currentModifier = state.modifier(for: preset.id)

        Button {
            state.activePresetID = preset.id
            state.clearBinding(for: preset.id)
        } label: {
            Label("Set as main preset", systemImage: isMain ? "checkmark" : "")
        }

        Divider()

        Button {
            state.clearBinding(for: preset.id)
        } label: {
            Label("No modifier", systemImage: !isMain && currentModifier == nil ? "checkmark" : "")
        }
        .disabled(isMain)

        ForEach(CapsModifier.allCases) { modifier in
            Button {
                state.bindModifier(modifier, to: preset.id)
            } label: {
                Label("\(modifier.symbol) \(modifier.displayName)", systemImage: currentModifier == modifier ? "checkmark" : "")
            }
            .disabled(isMain)
        }

        Divider()

        Button {
            toggleRotation(preset.id)
        } label: {
            Label(
                preset.excludedFromRotation ? "Show in rotation" : "Hide from rotation",
                systemImage: preset.excludedFromRotation ? "eye" : "eye.slash"
            )
        }

        Divider()

        Button("Duplicate") { duplicate(preset) }
        if preset.isBuiltIn {
            Button("Reset…") { pendingReset = preset }
                .disabled(!preset.isChangedBuiltIn)
        } else {
            Button("Delete…", role: .destructive) { pendingDelete = preset }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedPresetID, let preset = coordinator.appState.presets.first(where: { $0.id == id }) {
            PresetDetailForm(
                preset: binding(for: id, fallback: preset),
                provider: coordinator.appState.selectedLLMProvider,
                onReset: { pendingReset = preset },
                onDelete: { pendingDelete = preset }
            )
            // A new form per preset, so Advanced starts collapsed.
            .id(id)
        } else {
            ContentUnavailableView(
                "No Preset Selected",
                systemImage: "text.badge.star",
                description: Text("Select a preset or make a new one.")
            )
        }
    }

    /// Bound by id, not by index, so deleting a preset never writes into
    /// another one.
    private func binding(for id: UUID, fallback: DictationPreset) -> Binding<DictationPreset> {
        Binding(
            get: { coordinator.appState.presets.first { $0.id == id } ?? fallback },
            set: { newValue in
                guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == id }) else { return }
                coordinator.appState.presets[index] = newValue
            }
        )
    }

    // MARK: - Actions

    private func addPreset() {
        let preset = DictationPreset.newCustom()
        coordinator.appState.presets.append(preset)
        selectedPresetID = preset.id
    }

    private func duplicate(_ preset: DictationPreset) {
        let copy = preset.duplicated()
        coordinator.appState.presets.append(copy)
        selectedPresetID = copy.id
    }

    private func delete(_ preset: DictationPreset) {
        guard !preset.isBuiltIn else { return }
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
        coordinator.appState.removePreset(id: preset.id)
        if selectedPresetID == nil {
            selectedPresetID = coordinator.appState.activePresetID
        }
    }

    private func reset(_ preset: DictationPreset) {
        guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        coordinator.appState.presets[index] = coordinator.appState.presets[index].resetToOriginal()
    }

    /// Apple Intelligence does not know every language Parakeet does.
    static func languageWarning(preset: DictationPreset, provider: LLMProviderType) -> String? {
        guard let code = preset.language,
              preset.requiresAI,
              provider == .appleIntelligence,
              !AppleIntelligenceLanguageSupport.supports(languageCode: code)
        else { return nil }
        return "Apple Intelligence does not support \(WhisperLanguage.displayName(for: code)). The AI steps of this preset will fail. Pick another AI provider or language."
    }

    private func toggleRotation(_ id: UUID) {
        guard let index = coordinator.appState.presets.firstIndex(where: { $0.id == id }) else { return }
        coordinator.appState.presets[index].excludedFromRotation.toggle()
    }
}

/// One row of the preset list: name, log and rotation marks, key badge.
private struct PresetListRow: View {
    let preset: DictationPreset
    let isMain: Bool
    let modifier: CapsModifier?

    var body: some View {
        HStack(spacing: 6) {
            Text(preset.name)
                .lineLimit(1)
            Spacer()
            if preset.output == .logEntry {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                    .help("Saves to the log")
            }
            if preset.excludedFromRotation {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .help("Hidden from Caps Lock + ←/→ rotation")
            }
            if isMain {
                KeyComboBadge(modifier: nil)
            } else if let modifier {
                KeyComboBadge(modifier: modifier)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The selected preset as a grouped form.
private struct PresetDetailForm: View {
    @Binding var preset: DictationPreset
    let provider: LLMProviderType
    let onReset: () -> Void
    let onDelete: () -> Void
    @State private var advancedExpanded = false

    var body: some View {
        SettingsForm {
            Section("Preset") {
                TextField("Name", text: $preset.name)
                Picker(selection: $preset.language) {
                    Text("Automatic").tag(String?.none)
                    ForEach(WhisperLanguage.all, id: \.code) { entry in
                        Text(entry.displayName).tag(Optional(entry.code))
                    }
                } label: {
                    SettingsLabel(title: "Language", note: "Pin a language so short phrases are not taken for another one.")
                }
                if let warning = PresetsPane.languageWarning(preset: preset, provider: provider) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Picker("Output", selection: $preset.output) {
                    ForEach(PresetOutput.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            }

            Section("Processing") {
                SettingsToggle(title: "Remove filler words", note: "Drops um, uh and similar words.", isOn: $preset.enableFillerRemoval)
                SettingsToggle(title: "Remove repeated words", note: "Drops a word you said twice in a row.", isOn: $preset.enableDedup)
                SettingsToggle(title: "AI formatting", note: "Adds punctuation and paragraphs with \(provider.displayName).", isOn: $preset.enableAIFormatting)
                SettingsToggle(title: "AI rewrite", note: "Rewrites the text with \(provider.displayName), using the rewrite prompt.", isOn: $preset.enableRewrite)
            }

            Section {
                if preset.output == .logEntry {
                    SettingsToggle(title: "Keep audio", note: "Also saves the recording as an .m4a file next to the entry.", isOn: $preset.keepAudio)
                } else {
                    Picker("Append at the end", selection: $preset.trailingCharacter) {
                        ForEach(TrailingCharacter.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    SettingsToggle(
                        title: "Press Return after inserting",
                        note: "Sends the text right away, for example in a chat box.",
                        isOn: $preset.sendReturnAfterInsert
                    )
                }
            } header: {
                Text("Output options")
            } footer: {
                if preset.output == .logEntry {
                    Text("Saves the text as a Markdown file in the Logs folder of your library. Nothing is typed.")
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    promptEditor("Formatting prompt", text: $preset.aiPrompt)
                    promptEditor("Rewrite prompt", text: $preset.rewritePrompt)
                    SettingsToggle(title: "Custom dictionary", note: preset.dictionarySummary, isOn: $preset.enableCustomDictionary)
                    if preset.enableCustomDictionary {
                        ForEach($preset.dictionaryEntries) { $entry in
                            HStack {
                                TextField("Find", text: $entry.find, prompt: Text("Find"))
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.tertiary)
                                TextField("Replace", text: $entry.replace, prompt: Text("Replace"))
                                Button {
                                    preset.dictionaryEntries.removeAll { $0.id == entry.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this word")
                            }
                            .labelsHidden()
                        }
                        Button("Add Word") {
                            preset.dictionaryEntries.append(DictionaryEntry(find: "", replace: ""))
                        }
                    }
                }
            }

            Section {
                if preset.isBuiltIn {
                    SettingsRow(title: "Original settings") {
                        Button("Reset…", action: onReset)
                            .disabled(!preset.isChangedBuiltIn)
                    }
                } else {
                    SettingsRow(title: "Delete this preset") {
                        Button("Delete…", role: .destructive, action: onDelete)
                    }
                }
            } footer: {
                if preset.isBuiltIn {
                    Text("Built-in presets can be changed. Reset brings back the original.")
                }
            }
        }
    }

    private func promptEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.callout)
                .frame(minHeight: 60)
        }
    }
}
```

- [ ] **Step 5: Swap the pane and delete the old one**

In `SettingsPaneContent`: `case .presets: PresetsSettingsView()` becomes `case .presets: PresetsPane()`. Delete `Roger/UI/PresetsSettingsView.swift` (`git rm Roger/UI/PresetsSettingsView.swift`). In `Roger/Services/MeetingRecording/MeetingRecordingService.swift` the comment `/// PresetsSettingsView's mismatch warning).` becomes `/// PresetsPane's language warning).`.

- [ ] **Step 6: Regenerate and run all tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `PresetEditingTests` (5) and `PresetLanguageWarningTests` (1) pass.

- [ ] **Step 7: Snapshots**

Run: `cd /Users/jordi/git/roger && scripts/settings-snapshots.sh /tmp/roger-settings-task6`
Open `settings-presets.png`, `settings-presets-min.png` and `settings-presets-dark.png`. Expected: the preset list (180 pt) with key badges, log and rotation marks and "+ New Preset" at the bottom; on the right the sections Preset (Name, Language with note, Output), Processing (four switches with notes naming the AI provider), Output options, a collapsed Advanced row and the Reset row with the built-in footer. At the minimum size the form is narrow (about 260 pt): notes wrap, nothing is cut. If it reads badly, report it; the list width is the spec's one fixed width.

- [ ] **Step 8: Manual check**

Run Roger from Xcode, Settings > Presets.
- The main preset is selected. Change Polished's language and a switch: Reset in the context menu and in the last section becomes active, asks, then brings the original back; the Caps Lock badge and "Hide from rotation" stay.
- "+ New Preset" adds "Custom" and selects it. Duplicate a built-in: "<name> Copy", custom. Delete the selected custom preset: it asks, the list selects the main preset, no other preset changed (check Plain and Polished names and switches).
- Advanced opens, both prompts edit, Custom dictionary on shows "No words", Add Word adds a row, the summary counts.
- Set Output to "Save as log entry": Output options show Keep audio and the footer; back to "Insert at cursor": Append at the end and Press Return.
- Context menu: Set as main preset, the Caps Lock modifiers and Hide from rotation behave as before. The popover cheat sheet follows.
- Pin a language Apple Intelligence does not support (for example Finnish) on Polished with Apple Intelligence as provider: the orange warning shows.

- [ ] **Step 9: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Models/PresetEditing.swift Roger/UI/Settings/PresetsPane.swift Roger/UI/Settings/SettingsRootView.swift Roger/Services/MeetingRecording/MeetingRecordingService.swift Roger/RogerTests/PresetEditingTests.swift Roger/Roger.xcodeproj
git commit -m "feat: presets pane with editable built-in presets and reset"
```

(`git rm` in Step 5 already staged the deletion.)

---

### Task 7: Microphone, Model, AI Provider and Files

**Files:**
- Create: `Roger/UI/Settings/MicrophonePane.swift`, `Roger/UI/Settings/ModelPane.swift`, `Roger/UI/Settings/AIProviderPane.swift`, `Roger/UI/Settings/FilesPane.swift`
- Modify: `Roger/Services/AudioDeviceLookup.swift` (transport type), `Roger/UI/Settings/SettingsKit.swift` (append `LocalPresetMenu`), `Roger/UI/Settings/SettingsRootView.swift` (four cases), `Roger/UI/SettingsView.swift` (delete `FileTranscriptionSettingsView` and `ModelSettingsView`)
- Delete: `Roger/UI/MicrophoneSettingsView.swift`, `Roger/UI/AIProviderSettingsView.swift`
- Test: `Roger/RogerTests/TranscriptionPanesTests.swift`

**Interfaces:**
- Consumes: kit from Task 5, `AudioCaptureService.probe()`, `AudioCaptureService.halStarvedAdvice`, `coordinator.relaunchApp()` (as part A left it), `coordinator.warmUpMicrophone()`, `coordinator.setupModel()`, `coordinator.uninstallModel()`, `KeychainManager`, `OllamaService`, `AppState.libraryLayout.kindFolder(.transcripts)`.
- Produces: `AudioDeviceLookup.transportName(of: AudioDeviceID) -> String?`, `AudioDeviceLookup.transportName(forType: UInt32) -> String?`, `LocalPresetMenu(title:note:presets:selection:currentName:)` (used again in Task 8), `MicrophonePane.deviceNote(isAutomatic:deviceName:transport:isConnected:)`, `AIProviderPane.menuTitle(_:appleIntelligenceAvailable:)`, `FilesPane.outputNote(_:transcriptsFolder:)`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/TranscriptionPanesTests.swift`:

```swift
import CoreAudio
import Foundation
import Testing
@testable import Roger

@MainActor
struct TranscriptionPanesTests {
    @Test func transportNames() {
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeBuiltIn) == "Built-in")
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeUSB) == "USB")
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeBluetoothLE) == "Bluetooth")
        #expect(AudioDeviceLookup.transportName(forType: kAudioDeviceTransportTypeContinuityCaptureWireless) == "iPhone")
        #expect(AudioDeviceLookup.transportName(forType: 0) == nil)
    }

    @Test func deviceNoteSaysWhatRogerRecordsFrom() {
        #expect(MicrophonePane.deviceNote(isAutomatic: true, deviceName: "MacBook Pro Microphone", transport: "Built-in", isConnected: true)
            == "Now: MacBook Pro Microphone, Built-in. Follows the macOS setting.")
        #expect(MicrophonePane.deviceNote(isAutomatic: false, deviceName: "Shure MV7", transport: "USB", isConnected: true)
            == "Shure MV7, USB")
        #expect(MicrophonePane.deviceNote(isAutomatic: false, deviceName: nil, transport: nil, isConnected: false)
            == "The saved device is not connected. Roger uses the system default until it is back.")
        #expect(MicrophonePane.deviceNote(isAutomatic: true, deviceName: nil, transport: nil, isConnected: true)
            == "Now: No input device. Follows the macOS setting.")
    }

    @Test func providerMenuSaysWhereTextGoes() {
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligenceAvailable: true) == "Apple Intelligence (local)")
        #expect(AIProviderPane.menuTitle(.appleIntelligence, appleIntelligenceAvailable: false) == "Apple Intelligence (macOS 26 or later)")
        #expect(AIProviderPane.menuTitle(.ollama, appleIntelligenceAvailable: true) == "Ollama (local)")
        #expect(AIProviderPane.menuTitle(.claude, appleIntelligenceAvailable: true) == "Claude (cloud)")
        #expect(AIProviderPane.menuTitle(.openai, appleIntelligenceAvailable: false) == "OpenAI (cloud)")
    }

    @Test func filesOutputNoteNamesTheFolder() {
        let folder = URL(fileURLWithPath: "/tmp/Lib/Transcripts", isDirectory: true)
        #expect(FilesPane.outputNote(.library, transcriptsFolder: folder) == "/tmp/Lib/Transcripts/YYYY/MM")
        #expect(FilesPane.outputNote(.alongsideSource, transcriptsFolder: folder)
            == "In the folder of the dropped file, as <file name>.md.")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' -only-testing:RogerTests/TranscriptionPanesTests 2>&1 | tail -20`
Expected: build fails with "type 'AudioDeviceLookup' has no member 'transportName'".

- [ ] **Step 3: Transport type**

In `Roger/Services/AudioDeviceLookup.swift`, right before `private static func hasInputChannels(`, add:

```swift
    /// How the device is connected, for example "USB". nil when Core Audio
    /// does not say.
    static func transportName(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return transportName(forType: value)
    }

    static func transportName(forType type: UInt32) -> String? {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "Aggregate device"
        case kAudioDeviceTransportTypeVirtual: return "Virtual device"
        default: return nil
        }
    }
```

- [ ] **Step 4: Local preset menu**

Append to `Roger/UI/Settings/SettingsKit.swift`:

```swift
/// Preset menu for meetings and files: presets with AI steps are shown
/// but cannot be picked, so these transcripts never reach an AI provider.
struct LocalPresetMenu: View {
    let title: String
    var note: String? = nil
    let presets: [DictationPreset]
    @Binding var selection: UUID
    /// The preset in use (the fallback when the stored one needs AI).
    let currentName: String

    var body: some View {
        SettingsRow(title: title, note: note) {
            Menu(currentName) {
                ForEach(presets) { preset in
                    Button {
                        if !preset.requiresAI { selection = preset.id }
                    } label: {
                        if preset.id == selection {
                            Label(menuTitle(preset), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(preset))
                        }
                    }
                    .disabled(preset.requiresAI)
                }
            }
            .fixedSize()
        }
    }

    private func menuTitle(_ preset: DictationPreset) -> String {
        preset.requiresAI ? "\(preset.name) (needs AI)" : preset.name
    }
}
```

- [ ] **Step 5: Write the four panes**

Create `Roger/UI/Settings/MicrophonePane.swift`:

```swift
import CoreAudio
import SwiftUI

/// Settings > Microphone: which input Roger records from, and a level test.
struct MicrophonePane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var devices: [AudioDeviceLookup.InputDevice] = []
    @State private var systemDefaultName: String?
    @State private var systemDefaultTransport: String?
    @State private var testResult: String?
    @State private var testing = false
    /// Peak of the last test, 0...1. The meter shows it.
    @State private var peak: Float = 0
    /// True when the last test hit the CoreAudio wedge (engine ran, zero
    /// buffers). Shows the Relaunch row.
    @State private var starved = false

    var body: some View {
        @Bindable var state = coordinator.appState
        let micAllowed = coordinator.permissionManager.microphoneAuthorized
        SettingsForm {
            Section("Input device") {
                Picker(selection: deviceSelection) {
                    Text("Automatic (System Default)").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                    if let uid = state.selectedInputDeviceUID, !devices.contains(where: { $0.id == uid }) {
                        Text("Saved device (not connected)").tag(Optional(uid))
                    }
                } label: {
                    SettingsLabel(title: "Microphone", note: deviceNote)
                }
            }

            Section {
                SettingsRow(
                    title: "Level",
                    note: micAllowed ? (testResult ?? "Speak and press Test.") : "Roger needs access to the microphone. See Permissions.",
                    noteColor: micAllowed ? SettingsResultColor.color(for: testResult) : .secondary
                ) {
                    HStack {
                        ProgressView(value: Double(min(max(peak, 0), 1)))
                            .frame(minWidth: 60, maxWidth: 140)
                        Button(testing ? "Testing…" : "Test") { runTest() }
                            .disabled(testing || !micAllowed)
                    }
                }
                if starved {
                    SettingsRow(title: "The audio system is stuck", note: AudioCaptureService.halStarvedAdvice) {
                        Button("Relaunch Roger") { coordinator.relaunchApp() }
                    }
                }
            } header: {
                Text("Test")
            } footer: {
                Text("The meter shows the loudest moment of the last test. Roger only uses the microphone while it records or tests.")
            }
        }
        .onAppear { refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private var deviceSelection: Binding<String?> {
        Binding(
            get: { coordinator.appState.selectedInputDeviceUID },
            set: { uid in
                coordinator.appState.selectedInputDeviceUID = uid
                Task { await coordinator.warmUpMicrophone() }
            }
        )
    }

    private var deviceNote: String {
        let uid = coordinator.appState.selectedInputDeviceUID
        let device = uid.flatMap { uid in devices.first { $0.id == uid } }
        return Self.deviceNote(
            isAutomatic: uid == nil,
            deviceName: device?.name ?? systemDefaultName,
            transport: device.flatMap { AudioDeviceLookup.transportName(of: $0.deviceID) } ?? (uid == nil ? systemDefaultTransport : nil),
            isConnected: uid == nil || device != nil
        )
    }

    /// The note under the device menu: what Roger records from right now.
    static func deviceNote(isAutomatic: Bool, deviceName: String?, transport: String?, isConnected: Bool) -> String {
        guard isConnected else {
            return "The saved device is not connected. Roger uses the system default until it is back."
        }
        let name = deviceName ?? "No input device"
        let described = transport.map { "\(name), \($0)" } ?? name
        return isAutomatic ? "Now: \(described). Follows the macOS setting." : described
    }

    // MARK: - Actions

    private func refresh() {
        devices = AudioDeviceLookup.availableInputs()
        systemDefaultName = AudioDeviceLookup.systemDefaultInputName
        systemDefaultTransport = AudioDeviceLookup.systemDefaultInputID.flatMap(AudioDeviceLookup.transportName(of:))
    }

    private func runTest() {
        testResult = nil
        testing = true
        starved = false
        peak = 0
        let service = coordinator.audioCaptureService
        service.preferredInputUID = coordinator.appState.selectedInputDeviceUID
        let expectedDeviceName = devices.first { $0.id == coordinator.appState.selectedInputDeviceUID }?.name
            ?? systemDefaultName ?? "System Default"
        Task {
            do {
                let result = try await service.probe()
                let actualDefault = AudioDeviceLookup.systemDefaultInputName ?? "unknown"
                if let samples = result.samples, !samples.isEmpty {
                    peak = samples.map { abs($0) }.max() ?? 0
                    testResult = "OK: peak \(String(format: "%.3f", peak))"
                } else if result.health == .halStarved {
                    starved = true
                    testResult = "Failed - audio system is stuck"
                } else {
                    let routingHint = expectedDeviceName != actualDefault
                        ? " (system default: \(actualDefault))"
                        : ""
                    testResult = "Failed: 0 samples from \(expectedDeviceName)\(routingHint). Check mic privacy settings or MDM audio policy."
                }
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
```

Create `Roger/UI/Settings/ModelPane.swift`:

```swift
import SwiftUI

/// Settings > Model: the speech model, its status, Download and Remove.
struct ModelPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var confirmRemove = false

    var body: some View {
        let isSettingUp = coordinator.isSettingUpModel
        let isReady = coordinator.isModelReady
        SettingsForm {
            Section {
                SettingsRow(title: "Model", note: "Runs on your Mac with the Neural Engine. Your voice never leaves your Mac.") {
                    Text(TranscriptionEngine.modelName)
                        .foregroundStyle(.secondary)
                }
                SettingsRow(
                    title: "Status",
                    note: coordinator.lastModelError,
                    noteColor: .red
                ) {
                    HStack {
                        if isSettingUp {
                            if let progress = coordinator.modelSetupProgress {
                                ProgressView(value: progress.fraction)
                                    .frame(minWidth: 60, maxWidth: 140)
                                Text(progress.stage)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                                Text("Loading…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if isReady {
                            SettingsStatus(level: .good, text: "Downloaded")
                            Button("Remove…", role: .destructive) { confirmRemove = true }
                        } else {
                            SettingsStatus(level: .bad, text: "Not downloaded")
                            Button("Download") {
                                Task { await coordinator.setupModel() }
                            }
                        }
                    }
                }
            } header: {
                Text("Speech model")
            }
        }
        .confirmationDialog("Remove the speech model?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task { await coordinator.uninstallModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roger deletes the model from your Mac. You can download it again at any time.")
        }
    }
}
```

Create `Roger/UI/Settings/AIProviderPane.swift`:

```swift
import SwiftUI

/// Settings > AI Provider: which AI formats and rewrites text, and its
/// settings. API keys stay in the keychain.
struct AIProviderPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var claudeKey: String = KeychainManager.loadAPIKey(for: .claude) ?? ""
    @State private var openAIKey: String = KeychainManager.loadAPIKey(for: .openai) ?? ""
    @State private var testingConnection = false
    @State private var connectionStatus: String?

    private static var isAppleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        @Bindable var state = coordinator.appState
        let provider = state.selectedLLMProvider
        SettingsForm {
            Section {
                Picker(selection: $state.selectedLLMProvider) {
                    ForEach(LLMProviderType.allCases) { choice in
                        Text(Self.menuTitle(choice, appleIntelligenceAvailable: Self.isAppleIntelligenceAvailable))
                            .tag(choice)
                    }
                } label: {
                    SettingsLabel(
                        title: "Provider",
                        note: provider.isLocal ? "Your text stays on your Mac or in your network." : "Your text is sent to \(provider.displayName)."
                    )
                }
            } header: {
                Text("Provider")
            } footer: {
                if !provider.isLocal {
                    Label("Dictated text is sent to the servers of \(provider.displayName) for processing.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            switch provider {
            case .appleIntelligence:
                Section("Apple Intelligence") {
                    SettingsRow(title: "Availability", note: "Needs macOS 26 with Apple Intelligence turned on. Your text never leaves your Mac.") {
                        SettingsStatus(
                            level: Self.isAppleIntelligenceAvailable ? .good : .bad,
                            text: Self.isAppleIntelligenceAvailable ? "Available" : "Needs macOS 26"
                        )
                    }
                }
            case .ollama:
                Section {
                    TextField("Base URL", text: $state.ollamaBaseURL)
                    TextField("Model", text: $state.ollamaModel)
                    SettingsRow(
                        title: "Connection",
                        note: connectionStatus,
                        noteColor: SettingsResultColor.color(for: connectionStatus)
                    ) {
                        HStack {
                            if testingConnection {
                                ProgressView().controlSize(.small)
                            }
                            Button("Test Connection") { testOllamaConnection() }
                                .disabled(testingConnection)
                        }
                    }
                } header: {
                    Text("Ollama")
                } footer: {
                    Text("Ollama runs on your Mac or on another computer in your network. Your text stays there.")
                }
            case .claude:
                Section {
                    SecureField("API key", text: $claudeKey)
                        .onChange(of: claudeKey) { _, newValue in saveKey(newValue, for: .claude) }
                    TextField("Model", text: $state.claudeModel)
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Roger keeps the key in your keychain.")
                }
            case .openai:
                Section {
                    SecureField("API key", text: $openAIKey)
                        .onChange(of: openAIKey) { _, newValue in saveKey(newValue, for: .openai) }
                    TextField("Model", text: $state.openAIModel)
                } header: {
                    Text("OpenAI")
                } footer: {
                    Text("Roger keeps the key in your keychain.")
                }
            }
        }
    }

    /// Menu entry: the provider name and where the text goes.
    static func menuTitle(_ provider: LLMProviderType, appleIntelligenceAvailable: Bool) -> String {
        if provider == .appleIntelligence && !appleIntelligenceAvailable {
            return "\(provider.displayName) (macOS 26 or later)"
        }
        return "\(provider.displayName) (\(provider.isLocal ? "local" : "cloud"))"
    }

    // MARK: - Actions

    private func saveKey(_ key: String, for provider: LLMProviderType) {
        if key.isEmpty {
            try? KeychainManager.deleteAPIKey(for: provider)
        } else {
            try? KeychainManager.saveAPIKey(key, for: provider)
        }
    }

    private func testOllamaConnection() {
        testingConnection = true
        connectionStatus = nil
        Task {
            let service = OllamaService(
                baseURL: coordinator.appState.ollamaBaseURL,
                model: coordinator.appState.ollamaModel
            )
            let available = await service.isAvailable
            testingConnection = false
            connectionStatus = available ? "OK: connected" : "Cannot reach Ollama"
        }
    }
}
```

Create `Roger/UI/Settings/FilesPane.swift`:

```swift
import SwiftUI

/// Settings > Files: where transcripts of dropped audio and video files go
/// and how they are processed.
struct FilesPane: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var state = coordinator.appState
        SettingsForm {
            Section {
                Picker(selection: $state.fileTranscriptOutputLocation) {
                    ForEach(FileTranscriptOutputLocation.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    SettingsLabel(
                        title: "Save to",
                        note: Self.outputNote(state.fileTranscriptOutputLocation, transcriptsFolder: state.libraryLayout.kindFolder(.transcripts)),
                        truncatesNote: state.fileTranscriptOutputLocation == .library
                    )
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Drop an audio or video file on the menu bar icon. Roger saves the transcript as a Markdown file. It never overwrites a file, it adds a number.")
            }

            Section {
                LocalPresetMenu(
                    title: "Preset",
                    note: "Files are transcribed on your Mac. Presets with AI steps cannot be picked.",
                    presets: state.presets,
                    selection: $state.fileTranscriptionPresetID,
                    currentName: state.fileTranscriptionPreset.name
                )
                SettingsToggle(
                    title: "Speaker labels",
                    note: state.fileTranscriptionDiarize
                        ? "Adds [Speaker 0] and [Speaker 1] labels. The speaker models (about 150 MB) download the first time."
                        : "Adds a label for each speaker.",
                    isOn: $state.fileTranscriptionDiarize
                )
            } header: {
                Text("Processing")
            }
        }
    }

    /// The folder a transcript lands in.
    static func outputNote(_ location: FileTranscriptOutputLocation, transcriptsFolder: URL) -> String {
        switch location {
        case .library: return transcriptsFolder.path + "/YYYY/MM"
        case .alongsideSource: return "In the folder of the dropped file, as <file name>.md."
        }
    }
}
```

- [ ] **Step 6: Swap the panes and delete the old ones**

In `SettingsPaneContent`: `.microphone` > `MicrophonePane()`, `.model` > `ModelPane()`, `.aiProvider` > `AIProviderPane()`, `.files` > `FilesPane()`.

In `Roger/UI/SettingsView.swift` delete everything from `// MARK: - File Transcription` down to (not including) `// MARK: - About` (`FileTranscriptionSettingsView` and `ModelSettingsView`). Delete `Roger/UI/MicrophoneSettingsView.swift` and `Roger/UI/AIProviderSettingsView.swift` with `git rm`.

- [ ] **Step 7: Regenerate and run all tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`, `TranscriptionPanesTests` (4) pass, no "Restarting after unexpected exit".

- [ ] **Step 8: Snapshots**

Run: `cd /Users/jordi/git/roger && scripts/settings-snapshots.sh /tmp/roger-settings-task7`
Open the light, dark and min images of `microphone`, `model`, `aiProvider` and `files`. Expected: Microphone shows the device menu with "Now: <device>, <type>. Follows the macOS setting." (or the saved device), the Level row with an empty meter and Test; Model shows the model name and a status dot with Download (the snapshot run loads no model); AI Provider shows the provider menu and only the section of the chosen provider (keys as dots); Files shows Save to with the folder note and the Processing section.

- [ ] **Step 9: Manual check**

- Microphone: pick a USB or Bluetooth device, the note shows its type; unplug it, the menu shows "Saved device (not connected)" and the note explains the fallback; Test fills the meter and shows the peak. The orange microphone dot in the menu bar shows only during Test.
- Model: Remove asks, then deletes; Download shows the progress bar and stage; an error shows in red under Status.
- AI Provider: switch through the four providers; Claude and OpenAI keys survive a relaunch (keychain); Ollama Test Connection reports.
- Files: both Save to choices; the Preset menu shows AI presets as "(needs AI)" and does not pick them; Speaker labels note changes with the switch.

- [ ] **Step 10: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/UI/Settings/MicrophonePane.swift Roger/UI/Settings/ModelPane.swift Roger/UI/Settings/AIProviderPane.swift Roger/UI/Settings/FilesPane.swift Roger/UI/Settings/SettingsKit.swift Roger/UI/Settings/SettingsRootView.swift Roger/UI/SettingsView.swift Roger/Services/AudioDeviceLookup.swift Roger/RogerTests/TranscriptionPanesTests.swift Roger/Roger.xcodeproj
git commit -m "feat: microphone, model, AI provider and files panes in the shared kit"
```

---

### Task 8: Library & Meetings, Agents and About

**Files:**
- Create: `Roger/UI/Settings/LibraryPane.swift`, `Roger/UI/Settings/AboutPane.swift`
- Move and modify: `Roger/UI/AgentsSettingsView.swift` > `Roger/UI/Settings/AgentsPane.swift`
- Modify: `Roger/UI/Settings/SettingsRootView.swift` (three cases, drop the coordinator)
- Delete: `Roger/UI/SettingsView.swift`, `Roger/UI/RecordingsSettingsView.swift`

**Interfaces:**
- Consumes: kit and `LocalPresetMenu` (Tasks 5, 7), `coordinator.libraryChanges.reconcile()`, `coordinator.openLibrary()`, the Agents state and actions as part A left them (`AgentsController`, `AgentsLibraryStatus`, `ConsumerBookmarks`, `reload()`, `perform(_:)`).
- Produces: `LibraryPane`, `AgentsPane` (was `AgentsSettingsView`; `AgentsPane.documentsHint` keeps its text), `AboutPane`. After this task no old settings view is left.

This task has no new unit tests: it moves existing controls into the kit. The checks are the build, the full test run, the snapshots and the manual check.

- [ ] **Step 1: Write the Library & Meetings pane**

Create `Roger/UI/Settings/LibraryPane.swift`. The meeting recording shortcut moved to General in Task 5; the meeting transcript preset menu stays here (Ruling 12).

```swift
import AppKit
import SwiftUI

/// Settings > Library & Meetings: the library folder, older folders and
/// how meetings are recorded and transcribed.
struct LibraryPane: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showingFolderPicker = false

    var body: some View {
        @Bindable var state = coordinator.appState
        SettingsForm {
            Section {
                SettingsRow(
                    title: "Library folder",
                    note: state.libraryLayout.root.path + (state.libraryRoot == nil ? " (default)" : ""),
                    truncatesNote: true
                ) {
                    HStack {
                        Button("Choose…") { showingFolderPicker = true }
                        if state.libraryRoot != nil {
                            Button("Reset") {
                                state.libraryRoot = nil
                                // Part A Task 5: the default root is created here.
                                LibraryLayout.createRootIfDefault(state.libraryLayout)
                                coordinator.libraryChanges.reconcile()
                            }
                        }
                    }
                }
                HStack {
                    Button("Open Library") { coordinator.openLibrary() }
                    Button("Reveal in Finder") { revealLibraryFolder() }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Roger saves log entries, meetings and file transcripts here, in the folders Logs, Meetings and Transcripts, by year and month. Existing files stay where they are when you change the folder.")
            }

            if !state.extraScanFolders.isEmpty {
                Section {
                    ForEach(state.extraScanFolders, id: \.path) { folder in
                        SettingsRow(title: folder.lastPathComponent, note: folder.path, truncatesNote: true) {
                            Button("Forget") {
                                state.extraScanFolders.removeAll { $0 == folder }
                            }
                            .help("Stop looking for meetings in this folder. No files are deleted.")
                        }
                    }
                } header: {
                    Text("Older folders")
                } footer: {
                    Text("Roger still finds meetings in these folders. Forget stops that. No files are deleted.")
                }
            }

            Section("Meetings") {
                SettingsToggle(
                    title: "Keep audio",
                    note: "When off, Roger deletes mic.m4a and system.m4a once the transcript is written.",
                    isOn: $state.keepMeetingAudio
                )
                LocalPresetMenu(
                    title: "Preset",
                    note: "Cleans up the transcript on your Mac. Presets with AI steps cannot be picked.",
                    presets: state.presets,
                    selection: $state.meetingTranscriptionPresetID,
                    currentName: state.meetingTranscriptionPreset.name
                )
                SettingsToggle(
                    title: "Speaker labels for system audio",
                    note: state.meetingDiarizeSystem
                        ? "The other people show up as Other 1, Other 2 and so on."
                        : "Everything from system audio is labeled Other.",
                    isOn: $state.meetingDiarizeSystem
                )
                SettingsToggle(
                    title: "Speaker labels for the microphone",
                    note: "Turn this on when more than one person talks into your microphone. The main voice stays Me.",
                    isOn: $state.meetingDiarizeMic
                )
            }

            Section("Reliability") {
                SettingsRow(title: "New audio chunk every", note: "Long meetings are saved in chunks. A crash loses at most one chunk.") {
                    Stepper(value: $state.meetingMaxSegmentMinutes, in: 5 ... 60, step: 5) {
                        Text("\(state.meetingMaxSegmentMinutes) min")
                            .monospacedDigit()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.libraryRoot = url
                coordinator.libraryChanges.reconcile()
            }
        }
    }

    private func revealLibraryFolder() {
        let folder = coordinator.appState.libraryLayout.root
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
```

- [ ] **Step 2: Write the About pane**

Create `Roger/UI/Settings/AboutPane.swift`. It is the old `AboutView` unchanged, renamed:

```swift
import SwiftUI

/// Settings > About: icon, version, links and credits. Centered, not a form.
struct AboutPane: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            VStack(spacing: 4) {
                Text("Roger")
                    .font(.title.weight(.semibold))
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Speech-to-Text for macOS")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link(destination: URL(string: "https://ko-fi.com/V7V31T6CL9")!) {
                    Label("Support Me", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .controlSize(.regular)

                Link(destination: URL(string: "https://github.com/jordiboehme/roger")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Spacer()

            VStack(spacing: 10) {
                Text("Powered by [FluidAudio](https://github.com/FluidInference/FluidAudio), [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) & [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .tint(.accentColor)

                Text("Created with \u{2764}\u{FE0F} by Jordi Böhme  \u{00B7}  MIT License")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
```

- [ ] **Step 3: Move the Agents pane into the kit**

Run `git mv Roger/UI/AgentsSettingsView.swift Roger/UI/Settings/AgentsPane.swift`, then read the file (part A Task 22 changed how status, Start Over and Forget run). Keep the state (including part A's `manualChoice`), `ConsumerAction`, `documentsHint`, `root`, the `.task`/dialog/alert modifiers, `harnessRow`, `skillText`, `serverText`, the Actions section and `copyableBlock` with part A's logic. Change only:

1. `struct AgentsSettingsView: View {` becomes `struct AgentsPane: View {`.
2. In `body`, replace the `ScrollView { VStack(spacing: 16) { ... } .padding() }` block (the five cards and the `documentsHint` text) with:

```swift
        SettingsForm {
            librarySection
            harnessesSection
            desktopSection
            manualSetupSection
            consumersSection
        }
```

   The modifiers that followed the `ScrollView` (`.task`, `.confirmationDialog`, `.alert`, `.confirmationDialog`) now follow `SettingsForm`.
3. Replace everything from `// MARK: - Cards` down to (not including) `private func harnessRow(` with:

```swift
    // MARK: - Sections

    private var librarySection: some View {
        Section("Library") {
            VStack(alignment: .leading, spacing: 4) {
                Text(root.path)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Group {
                    if let status, status.isSetUp {
                        if let last = status.lastEventAt {
                            Text("\(status.eventCount) changes recorded, the last one \(last.formatted(.relative(presentation: .named))).")
                        } else {
                            Text("No changes recorded yet.")
                        }
                    } else {
                        Text("The change list is not set up yet. Roger sets it up when it starts.")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var harnessesSection: some View {
        Section("Coding agents") {
            if let agents {
                if case .unusable(let reason) = agents.executableChoice {
                    Text(reason).foregroundStyle(.orange)
                }
                if agents.rows.isEmpty {
                    Text("No coding agent found. Roger looks for Claude Code, Codex, Gemini CLI, Cursor, Copilot CLI and Kiro in your home folder.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agents.rows) { row in
                    harnessRow(row, agents: agents)
                }
            } else if agentsLoaded {
                Text("This copy of Roger has no ingest skill.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var desktopSection: some View {
        if let agents, agents.desktopAvailable {
            Section {
                if agents.desktopAppMoved() {
                    Text("Roger.app moved - add again.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Add to Claude Desktop") {
                        Task { await agents.addToClaudeDesktop() }
                    }
                    .disabled(agents.desktopBusy)
                    Button("Save Skill for Claude Desktop") {
                        Task { await agents.saveSkillForClaudeDesktop() }
                    }
                    .disabled(agents.desktopBusy)
                }
                if let added = agents.desktopRecord.extensionAddedAt {
                    Text("Extension last added \(added.formatted(.relative(presentation: .named))).")
                        .foregroundStyle(.secondary)
                }
                if let saved = agents.desktopRecord.skillSavedAt {
                    Text("Skill last saved \(saved.formatted(.relative(presentation: .named))).")
                        .foregroundStyle(.secondary)
                }
                if let message = agents.desktopMessage {
                    Text(message)
                }
            } header: {
                Text("Claude Desktop")
            } footer: {
                Text("Roger cannot see what Claude Desktop has installed. These lines show what Roger did last.")
            }
        }
    }
```

4. Replace `private var manualSetupCard: some View { ... }` and `private var consumersCard: some View { ... }` (down to, not including, `// MARK: - Actions`) with the code below. If part A changed what the Start Over and Forget buttons call, keep part A's calls inside the new buttons.

```swift
    private var manualSetupSection: some View {
        Section {
            DisclosureGroup("Manual setup") {
                VStack(alignment: .leading, spacing: 10) {
                    // `manualChoice` is part A's state (Task 22), looked up off the main actor.
                    switch manualChoice {
                    case .usable(let executable)?:
                        Text("Claude Code:")
                        copyableBlock(McpCommandFormatter.claudeAdd(executable: executable))
                        Text("Other clients (.mcp.json, Cursor, Copilot CLI, Kiro):")
                        copyableBlock(McpCommandFormatter.jsonSnippet(executable: executable))
                    case .unusable(let reason)?:
                        Text(reason).foregroundStyle(.secondary)
                    case nil:
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.top, 6)
            }
        } footer: {
            Text("Commands to add Roger to an agent yourself.")
        }
    }

    private var consumersSection: some View {
        Section {
            let consumers = status?.consumers ?? []
            if consumers.isEmpty {
                Text("No agent has read the library yet. Each agent keeps a bookmark here under its consumer name.")
                    .foregroundStyle(.secondary)
            }
            ForEach(consumers) { consumer in
                SettingsRow(
                    title: consumer.name,
                    note: "At change \(consumer.seq), \(consumer.openEvents) open, \(consumer.updatedAt.formatted(.relative(presentation: .named)))"
                ) {
                    HStack {
                        Button("Start Over") { consumerAction = .startOver(consumer.name) }
                        Button("Forget") { consumerAction = .forget(consumer.name) }
                    }
                }
            }
        } header: {
            Text("Consumers")
        } footer: {
            Text(Self.documentsHint)
        }
    }
```

5. In `harnessRow`: `Text(row.spec.name).font(.body.weight(.medium))` becomes `Text(row.spec.name)`, the line under it uses `.font(.subheadline)` instead of `.font(.caption)`, and `Text(message).font(.caption).foregroundStyle(.orange)` becomes `Text(message).font(.subheadline).foregroundStyle(.orange)`. In `copyableBlock` `.font(.system(size: 11, design: .monospaced))` becomes `.font(.callout.monospaced())`.
6. Delete `private func settingsCard(...)` at the end of the file.

Check: `grep -n "settingsCard\|font(.system" /Users/jordi/git/roger/Roger/UI/Settings/*.swift` prints nothing.

- [ ] **Step 4: Swap the panes and delete the rest of the old views**

`SettingsPaneContent` in `Roger/UI/Settings/SettingsRootView.swift` becomes (no coordinator needed any more):

```swift
/// The pane for a sidebar entry.
struct SettingsPaneContent: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralPane()
        case .presets: PresetsPane()
        case .microphone: MicrophonePane()
        case .model: ModelPane()
        case .aiProvider: AIProviderPane()
        case .files: FilesPane()
        case .library: LibraryPane()
        case .agents: AgentsPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}
```

Delete `Roger/UI/SettingsView.swift` (only `AboutView` was left) and `Roger/UI/RecordingsSettingsView.swift` with `git rm`.

Check: `grep -rn "AgentsSettingsView\|RecordingsSettingsView\|AboutView\|SettingsView()" /Users/jordi/git/roger/Roger --include='*.swift'` prints nothing.

- [ ] **Step 5: Regenerate and run all tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **` (part A's Agents tests included).

- [ ] **Step 6: Snapshots**

Run: `cd /Users/jordi/git/roger && scripts/settings-snapshots.sh /tmp/roger-settings-task8`
Open all three images of `library`, `agents` and `about`, then skim all 30 once: every pane is a grouped form (About is centered), no card look is left, the dark images are fully dark.

- [ ] **Step 7: Manual check**

- Library & Meetings: Choose… picks a folder, the path note follows, Reset appears and goes back to the default (the library window and the agents change list follow, `reconcile` runs); Open Library and Reveal in Finder work; Forget removes an older folder; the four meeting controls and the chunk stepper keep their values after a relaunch.
- Agents: Install, Update and Uninstall of a harness row, Manual setup opens, Start Over and Forget ask and work, Claude Desktop buttons (when Claude Desktop is installed).
- About: links open GitHub and Ko-fi.

- [ ] **Step 8: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/UI/Settings/LibraryPane.swift Roger/UI/Settings/AboutPane.swift Roger/UI/Settings/AgentsPane.swift Roger/UI/Settings/SettingsRootView.swift Roger/Roger.xcodeproj
git commit -m "feat: library, agents and about panes in the shared kit"
```

(`git mv` and `git rm` already staged the move and the deletions.)

---

### Task 9: Docs and the full check

**Files:**
- Modify: `README.md`, `AGENTS.md` (in place, ignored by git)

- [ ] **Step 1: README**

In `README.md`:
- `dedicated Microphone tab lets you pin` becomes `dedicated Microphone pane lets you pin`.
- `destination and preset live under Settings › File Transcription.` becomes `destination and preset live under Settings › Files.`
- `assign a global hotkey under Settings › Recordings.` becomes `assign a global hotkey under Settings › General.`
- `Change the library folder under Settings › Recordings.` becomes `Change the library folder under Settings › Library & Meetings.`
- `While the window is open, Roger shows up in the Dock and in Cmd-Tab.` becomes `While the library or Settings is open, Roger shows up in the Dock and in Cmd-Tab.`

Check: `grep -n "Settings › Recordings\|File Transcription\|Microphone tab" README.md` prints nothing.

- [ ] **Step 2: AGENTS.md (in place, never `git add`)**

- In the Agents bullet, `UI/AgentsSettingsView.swift` becomes `UI/Settings/AgentsPane.swift`.
- Replace the MenuBarView bullet with: `- **MenuBarView** - Status, presets cheat sheet, last transcription, library, settings and quit. Every "open Settings" place calls \`coordinator.openSettings(pane)\`.`
- Replace the SettingsView bullet with: `- **SettingsWindowController** (\`App/\`) - NSWindow + NSHostingController for \`SettingsRootView\` (\`UI/Settings/\`): a System-Settings-like sidebar of \`SettingsPane\`s (General, Presets, Microphone; Transcription: Model, AI Provider, Files; Library: Library & Meetings, Agents; Permissions, About). Every pane is a \`SettingsForm\` built from the kit in \`SettingsKit.swift\` (\`SettingsRow\`, \`SettingsToggle\`, \`SettingsBanner\`, \`SettingsStatus\`). \`AppWindowPresence\` keeps Roger in the Dock while the library or Settings is open. The \`Settings\` scene in \`RogerApp\` is empty and only carries the Cmd-, command.`
- In the RogerApp bullet, `Settings via \`Settings\` scene.` becomes `Settings in their own window (SettingsWindowController).`
- Replace the convention `- Settings opened via \`SettingsLink\` + \`simultaneousGesture\` (not \`openWindow\` or selectors)` with `- Settings open through \`coordinator.openSettings(pane)\`, never \`SettingsLink\`. Settings panes are grouped forms from the shared kit, no fixed font sizes, no custom cards.`
- Under Build & Run add: `Settings screenshots (Debug): \`scripts/settings-snapshots.sh <empty folder>\` renders every pane light, dark and at the minimum size (30 PNGs).`

- [ ] **Step 3: Full check**

Run:

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "warning: .*Settings|error:|BUILD"
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS,arch=arm64' 2>&1 | tail -10
cd /Users/jordi/git/roger && scripts/version-pins.sh
cd /Users/jordi/git/roger && grep -rn "—\|–" Roger/UI/Settings Roger/App/SettingsWindowController.swift Roger/App/SettingsSnapshotRunner.swift Roger/App/AppWindowPresence.swift Roger/Services/CapsLockRemap.swift scripts/settings-snapshots.sh
cd /Users/jordi/git/roger && scripts/settings-snapshots.sh /tmp/roger-settings-final
```

Expected: `** BUILD SUCCEEDED **` without new warnings in settings files, `** TEST SUCCEEDED **`, `version-pins.sh` passes (part A's state, no version change here), the dash grep prints nothing, `30 images in /tmp/roger-settings-final`.

`version-pins.sh` fails when `release-notes/v<current version>.md` is missing; if it fails only for that reason, note it in the report (release notes are a separate step) and go on.

- [ ] **Step 4: Manual checks from the spec**

- Cmd-Tab and the Dock while Settings is open, alone and together with the library (both closing orders).
- Every "open Settings" link lands on its pane: popover Settings (last pane), popover pencil (Presets), agent hint (Agents), library Logs empty state (Presets), General banner (Permissions), General "Set Up Caps Lock" (Permissions), Cmd-, (last pane).
- Each pane at the minimum size (640 × 460): nothing cut off (compare with the `-min` images).
- Dark mode (System Settings > Appearance > Dark): every pane.
- Onboarding (on a test user or after `defaults delete com.jordiboehme.roger hasCompletedOnboarding`) is unchanged.

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add README.md
git commit -m "docs: settings panes in the README"
```

---

## Self-Review

**Spec coverage.** Structure and sidebar (section 1): Tasks 2, 3. Pane contents (section 2): General and Permissions Task 5, Presets Task 6, Microphone, Model, AI Provider, Files Task 7, Library & Meetings, Agents, About Task 8. Shared kit (section 3): Task 5 (plus `LocalPresetMenu` in Task 7); the copied `settingsCard`/`settingsRow` helpers go with their views in Tasks 5 to 8. Window (section 4): Task 3, `AppWindowPresence` Task 1. Behavior that stays (section 5): Ruling 12, every task keeps the `AppState` properties and keys; nothing writes a new value except `settingsLastPane` and the window frame. Snapshots (section 6): Task 4 (moved forward, Ruling 1). Testing: `SettingsPane` mapping (Task 2 `everyOldTabHasItsPane`), `AppWindowPresence` counting with an injected policy setter (Task 1), `show(pane)` selects and reuses (Task 3), snapshot of all ten panes (Task 4 and every UI task), the four manual checks (Task 9 Step 4). Deviations, all in Rulings: the empty `Settings` scene stays (2), the level meter shows the last test (8), built-in presets became editable as the spec says (11).

**Placeholder scan.** No TBD or "similar to Task N"; every code step has the full file or the exact old and new text. The two places where part A's text is unknown (the `RogerApp.body` and the Agents actions) say exactly what to keep and what to replace.

**Type consistency.** `SettingsPane` cases and raw values, `SettingsPaneMemory.standard`/`.none`, `SettingsNavigation(memory:)`, `SettingsWindowController(presence:memory:frameAutosaveName:present:makeContent:)`, `AppWindowPresence.enter/leave(.library | .settings)`, `AppCoordinator.openSettings(_:)`, `AppDelegate.showSettings(_:)` and `makeSettingsWindowController(memory:frameAutosaveName:)`, the kit initializers and `LocalPresetMenu(title:note:presets:selection:currentName:)` are used with the same names and labels in every task.

**Review Focus.** Each of the five lines has its test in the owning task (Tasks 1, 2, 5, 6). The preset delete and the out-of-range durations are manual checks with the reason stated.

**What was checked before writing (2026-10-14, Xcode 27.0, Swift 6.4, XcodeGen 2.46.0).** All of it ran on code from before part A; the part A edits named in Ruling 17 were read from part A's plan and ported by hand, not compiled.
- A scratch Swift package with `AppWindowPresence`, `SettingsPane`, `SettingsNavigation`, `SettingsPaneMemory`, `CapsLockRemap`, the transport mapping, `SettingsFormat`, `PresetEditing` (with the real `DictationPreset.swift`), `SettingsWindowController`, `SettingsRootView`, the kit, the empty `Settings` scene with `CommandGroup(replacing: .appSettings)`, `DisclosureGroup` in a grouped form and `confirmationDialog(presenting:)`: it compiles under Swift 6 strict concurrency, and the 33 tests pass.
- A copy of the repository (state before part A) with every task of this plan applied: Debug build succeeds, the full Roger scheme test run passes (309 RogerTests, 107 RogerKitTests), and the snapshot mode wrote all 30 PNGs without writing `settingsLastPane` or the window frame; `scripts/settings-snapshots.sh` itself ran end to end (build, render, count 30). No new warning in the new files. That run found three things now in the plan: tests calling `View` statics must be `@MainActor` (they crashed), `UserDefaults(suiteName:)` in tests leaves plist files (replaced by closures), and SwiftUI ignores the sidebar column width in this window (Ruling 6, fixed in the controller).
- `hidutil property --get UserKeyMapping` on this Mac prints the decimal values the parser looks for.

**Known doubts (for Jordi).**
- The empty `Settings` scene cannot go (Ruling 2).
- Built-in presets become editable with Reset: a behavior change the spec asks for, not only a new look (Ruling 11).
- At the minimum window size the Presets pane has three columns (sidebar 200, list 180, form about 260 pt). It works but is tight; check `settings-presets-min.png`.
- The spec's "live level meter" would keep the microphone open; the plan shows the last test instead (Ruling 8).
- The snapshot render sometimes draws the selected sidebar row as a black bar (a `cacheDisplay` limit); on screen it is the accent color.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-10-14-settings-overhaul-0.26.0.md`. Please review the plan. Which execution approach would you prefer?

- **Subagent-driven** - A fresh subagent implements each task and a fresh reviewer checks it before the next one starts, then a whole-branch review at the end. Most thorough; costs a fresh context per task and per review.
- **Native** - I implement every task myself in this session, the way this harness runs work, then one fresh reviewer on the most capable model checks the whole branch. Cheapest and fastest; no independent review until the end. Runs well with a mid-tier session model, since the plan carries the design.

For this plan I recommend subagent-driven, because the nine tasks build on each other's names (pane enum, window controller, kit) and a look that only shows in snapshots is easy to get wrong unnoticed, so a review with the PNGs after each task is worth its cost. Does the plan capture what you want, and which approach should we use?
