# Log Entries Phase 1 (Library Foundation and Log Entries) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A preset can save speech as a Markdown log entry in a library folder (`~/Documents/Roger/Logs/YYYY/MM/`) instead of typing it, and meetings and file transcripts move into the same library.

**Architecture:** A pure `LibraryLayout` value resolves all paths from one configurable root. `DictationPreset` gets an `output` target and `keepAudio`. `AppCoordinator.runPipeline` branches to a new `LogEntryWriter` for log presets. Meetings and file transcripts write into the library; a one-time migration moves old meeting folders. A new `RogerTests` target (Swift Testing, hosted in Roger.app) covers all pure logic.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, AVFoundation, XcodeGen, Swift Testing, macOS 15+.

**Spec:** `docs/superpowers/specs/2026-10-13-log-entries-and-library-design.md` (sections 1, 2, 6, 7 and the phase 1 list in section 8).

## Global Constraints

- Work on branch `feat/log-entries-library` in `/Users/jordi/git/roger`.
- macOS 15.0 deployment target, Swift 6 strict concurrency, `@MainActor` for `@Observable` types SwiftUI observes.
- Logging via `os.Logger` with subsystem `com.jordiboehme.roger`.
- Commits: plain conventional-commit messages. NEVER add `Co-Authored-By`, "Generated with Claude Code" or any AI attribution.
- User-facing strings (UI text, alerts, docs): no em-dash "—" or en-dash (use "-"), no Oxford comma ("A, B and C"), short plain sentences. Author name is "Jordi Böhme".
- Debug builds: `cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | tail -20`. Never pass `CONFIGURATION_BUILD_DIR` for Debug.
- Tests: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -40`. Add `-only-testing:RogerTests/<SuiteName>` to run one suite.
- After every `xcodegen generate`: run `git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements` (xcodegen empties it), check `git diff Roger/Resources/Roger.entitlements` is empty, and commit the regenerated `Roger/Roger.xcodeproj` (it is tracked).
- Tests run inside the real Roger.app (same bundle ID, so `UserDefaults.standard` is the developer's live settings). Tests must NEVER construct `AppState` or `AppCoordinator`, never write to `UserDefaults.standard` and never touch `~/Documents`. Use `FileManager.default.temporaryDirectory` subfolders and injected roots and dates.
- Library layout: root (default `~/Documents/Roger/`) with `Logs/YYYY/MM/`, `Meetings/YYYY/MM/<session>/`, `Transcripts/YYYY/MM/`. Year and month from the local recording start.
- Log entry files: `<yyyy-MM-dd HH-mm-ss>.md`, optional `<same>.m4a`; collisions get ` 1`, ` 2`. File names never change after writing.
- Log entry frontmatter keys and order come from `TranscriptFrontmatter` (OKF). Tags `[log]`. `sources` uses `{ id: audio, resource: "<file>.m4a" }` and appears only when audio was kept.
- Log title: `Log <yyyy-MM-dd HH:mm> - <first 6 words>`; H1: `# Log <yyyy-MM-dd HH:mm>`.
- Built-in Log preset UUID `00000000-0000-0000-0000-000000000008`.

## Review Focus

1. A log preset whose AI step is unavailable or refused by the guardrail must still save to the log and must never type text at the cursor. (Task 3 test on `withoutAI`, Task 5 guardrail branch.)
2. Crash recovery must find unfinished meetings in the nested `Meetings/YYYY/MM/` layout and in legacy extra scan folders. (Task 6 scanner tests.)
3. When the library folder cannot be written, the log text must not be lost: it stays in `lastTranscription` with an error. (Task 4 test for the thrown error, Task 5 catch branch.)
4. Two log entries in the same second, or an existing file with the same name, must never overwrite each other, including the `.m4a`. (Task 4 `uniqueBaseName` test.)
5. If audio encoding fails, the `.md` is still written, without `sources`, and no partial `.m4a` stays behind. (Task 4 failing-encoder test.)
6. Migration into a month folder that already has a session with the same name must not overwrite it. (Task 8 executor test.)

---

### Task 1: Test target and launch guard

**Files:**
- Modify: `Roger/project.yml`
- Modify: `Roger/App/RogerApp.swift` (top of `applicationDidFinishLaunching`)
- Create: `Roger/RogerTests/TranscriptFrontmatterTests.swift`
- Modify: `.github/workflows/ci.yml` (add a test step after Build)
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Produces: a `RogerTests` Swift Testing target with `@testable import Roger`, run via the `Roger` scheme.

- [ ] **Step 1: Add the test target to project.yml**

Under `targets.Roger` add a scheme block (same indentation as `dependencies:`):

```yaml
    scheme:
      testTargets:
        - RogerTests
```

Add a new target after `Roger`:

```yaml
  RogerTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: RogerTests
    dependencies:
      - target: Roger
    settings:
      base:
        SWIFT_VERSION: "6.0"
        MACOSX_DEPLOYMENT_TARGET: "15.0"
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: 77PA95K95V
        PRODUCT_BUNDLE_IDENTIFIER: com.jordiboehme.roger.tests
```

- [ ] **Step 2: Guard app launch under XCTest**

In `AppDelegate.applicationDidFinishLaunching`, as the very first statement (before `let coordinator = sharedCoordinator`):

```swift
        // Unit tests run inside Roger.app. Skip the event tap, model
        // download, mic warm-up and onboarding there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
```

- [ ] **Step 3: Write a first test**

`Roger/RogerTests/TranscriptFrontmatterTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct TranscriptFrontmatterTests {
    @Test func quotesQuotesAndNewlines() {
        #expect(TranscriptFrontmatter.quoted("a \"b\"\nc") == "\"a \\\"b\\\"\\nc\"")
    }

    @Test func dayIsPlainDate() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 13; c.hour = 14; c.minute = 32
        let date = Calendar.current.date(from: c)!
        #expect(TranscriptFrontmatter.day(date) == "2026-10-13")
    }
}
```

- [ ] **Step 4: Generate, restore entitlements, run tests**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 2 tests passed. Roger must not show onboarding or start the hotkey during the run.

- [ ] **Step 5: Check the CI-style unsigned run works**

```bash
cd /Users/jordi/git/roger && xcodebuild test -project Roger/Roger.xcodeproj -scheme Roger -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. If it fails only because of signing of the test host, try `CODE_SIGN_IDENTITY="-"` with `CODE_SIGNING_ALLOWED=YES` (ad-hoc) and use whatever passes in the CI step below. Report what you used.

- [ ] **Step 6: Add the CI step**

In `.github/workflows/ci.yml`, job `build`, after the `Build` step and before `Verify app bundle`, add (same flags as the command that passed in Step 5):

```yaml
      - name: Test
        run: |
          xcodebuild test -project Roger/Roger.xcodeproj \
            -scheme Roger \
            -destination 'platform=macOS' \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger && git add Roger/project.yml Roger/Roger.xcodeproj Roger/RogerTests Roger/App/RogerApp.swift .github/workflows/ci.yml
git commit -m "test: add a unit test target"
```

---

### Task 2: LibraryLayout and library settings

**Files:**
- Create: `Roger/Models/LibraryLayout.swift`
- Modify: `Roger/App/AppState.swift`
- Create: `Roger/RogerTests/LibraryLayoutTests.swift`
- Regenerated: `Roger/Roger.xcodeproj` (new files)

**Interfaces:**
- Produces:
  - `struct LibraryLayout: Sendable, Equatable { let root: URL; enum Kind: String { case logs = "Logs", meetings = "Meetings", transcripts = "Transcripts" }; static var defaultRoot: URL; static var legacyRecordingsFolder: URL; func kindFolder(_ kind: Kind) -> URL; func monthFolder(_ kind: Kind, for date: Date, calendar: Calendar = .current) -> URL }`
  - `AppState.libraryRoot: URL?` (nil = default), `AppState.libraryLayout: LibraryLayout`, `AppState.extraScanFolders: [URL]`, `AppState.keepMeetingAudio: Bool` (default true), `AppState.libraryMigrationDone: Bool`, `AppState.lastLogEntryURL: URL?` (runtime only), `AppState.legacyMeetingRecordingsFolder: URL?`, `AppState.legacyFileTranscriptFolder: URL?`.

- [ ] **Step 1: Write the failing test**

`Roger/RogerTests/LibraryLayoutTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryLayoutTests {
    let root = URL(fileURLWithPath: "/tmp/RogerLib", isDirectory: true)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    @Test func kindFolders() {
        let layout = LibraryLayout(root: root)
        #expect(layout.kindFolder(.logs).path == "/tmp/RogerLib/Logs")
        #expect(layout.kindFolder(.meetings).path == "/tmp/RogerLib/Meetings")
        #expect(layout.kindFolder(.transcripts).path == "/tmp/RogerLib/Transcripts")
    }

    @Test func monthFolderIsZeroPadded() {
        let layout = LibraryLayout(root: root)
        #expect(layout.monthFolder(.logs, for: date(2026, 3, 5)).path == "/tmp/RogerLib/Logs/2026/03")
        #expect(layout.monthFolder(.meetings, for: date(2026, 10, 13)).path == "/tmp/RogerLib/Meetings/2026/10")
    }

    @Test func defaultRootIsRogerInDocuments() {
        #expect(LibraryLayout.defaultRoot.lastPathComponent == "Roger")
        #expect(LibraryLayout.defaultRoot.deletingLastPathComponent().lastPathComponent == "Documents")
        #expect(LibraryLayout.legacyRecordingsFolder.lastPathComponent == "Roger Recordings")
    }
}
```

- [ ] **Step 2: Implement LibraryLayout**

`Roger/Models/LibraryLayout.swift`:

```swift
import Foundation

/// Folder layout of Roger's library: one root with `Logs/`, `Meetings/` and
/// `Transcripts/`, each split into `YYYY/MM/` by the local recording time.
/// The single place that knows where Roger's files go.
struct LibraryLayout: Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case logs = "Logs"
        case meetings = "Meetings"
        case transcripts = "Transcripts"
    }

    let root: URL

    /// `~/Documents/Roger/`.
    static var defaultRoot: URL {
        documents.appendingPathComponent("Roger", isDirectory: true)
    }

    /// Where meetings went before the library existed: `~/Documents/Roger Recordings/`.
    static var legacyRecordingsFolder: URL {
        documents.appendingPathComponent("Roger Recordings", isDirectory: true)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    func kindFolder(_ kind: Kind) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    /// `<root>/<Kind>/YYYY/MM/` for the local month of `date`.
    func monthFolder(_ kind: Kind, for date: Date, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        return kindFolder(kind)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
    }
}
```

- [ ] **Step 3: Add the settings to AppState**

In `Roger/App/AppState.swift`:

1. Under `var lastTranscription: String?` add:

```swift
    /// The `.md` written by the last log entry, nil after a normal dictation.
    var lastLogEntryURL: URL?
```

2. Add a new section before `// MARK: - Meeting Recording Settings`:

```swift
    // MARK: - Library Settings

    /// Root of the library (Logs, Meetings, Transcripts). nil resolves to
    /// `~/Documents/Roger/`.
    var libraryRoot: URL? {
        didSet {
            if let url = libraryRoot {
                defaults.set(url.path, forKey: "libraryRoot")
            } else {
                defaults.removeObject(forKey: "libraryRoot")
            }
        }
    }

    var libraryLayout: LibraryLayout {
        LibraryLayout(root: libraryRoot ?? LibraryLayout.defaultRoot)
    }

    /// Older folders that still hold meetings or transcripts. Scanned for
    /// unfinished meetings and listed in the Recordings settings.
    var extraScanFolders: [URL] {
        didSet { defaults.set(extraScanFolders.map(\.path), forKey: "extraScanFolders") }
    }

    /// When false, mic.m4a and system.m4a are deleted once the meeting
    /// transcript is written.
    var keepMeetingAudio: Bool {
        didSet { defaults.set(keepMeetingAudio, forKey: "keepMeetingAudio") }
    }

    /// Set once the one-time move into the library has run (or was declined).
    var libraryMigrationDone: Bool {
        didSet { defaults.set(libraryMigrationDone, forKey: "libraryMigrationDone") }
    }

    /// Pre-library meetings folder setting, read by the migration only.
    var legacyMeetingRecordingsFolder: URL? {
        defaults.string(forKey: "meetingRecordingsFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Pre-library custom folder for file transcripts, read by the migration only.
    var legacyFileTranscriptFolder: URL? {
        defaults.string(forKey: "fileTranscriptOutputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
```

3. In `init()`, before `if let path = defaults.string(forKey: "meetingRecordingsFolder")`, add:

```swift
        self.libraryRoot = defaults.string(forKey: "libraryRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.extraScanFolders = (defaults.stringArray(forKey: "extraScanFolders") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.keepMeetingAudio = defaults.object(forKey: "keepMeetingAudio") as? Bool ?? true
        self.libraryMigrationDone = defaults.bool(forKey: "libraryMigrationDone")
```

Leave `meetingRecordingsFolder` and `fileTranscriptOutputFolder` in place for now; Tasks 6 and 7 remove them.

- [ ] **Step 4: Generate project, build, run tests**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryLayoutTests 2>&1 | tail -20
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger && git add Roger/Models/LibraryLayout.swift Roger/App/AppState.swift Roger/RogerTests/LibraryLayoutTests.swift Roger/Roger.xcodeproj
git commit -m "feat: add the library folder layout and settings"
```

---

### Task 3: Preset output target, keepAudio and the Log preset

**Files:**
- Modify: `Roger/Models/DictationPreset.swift`
- Modify: `Roger/App/AppCoordinator.swift` (`nonAIFallback`, around line 430)
- Modify: `Roger/UI/PresetsSettingsView.swift` (`addCustomPreset` ~line 308, `duplicatePreset` ~line 333)
- Create: `Roger/RogerTests/DictationPresetTests.swift`

**Interfaces:**
- Produces:
  - `enum PresetOutput: String, Codable, CaseIterable, Identifiable { case insertAtCursor, logEntry; var displayName: String }`
  - `DictationPreset.output: PresetOutput` (default `.insertAtCursor`), `DictationPreset.keepAudio: Bool` (default `false`), init parameters `output:` and `keepAudio:` after `language:`.
  - `DictationPreset.withoutAI: DictationPreset` (copy with AI formatting and rewrite off, everything else kept).
  - `DictationPreset.log` (built-in, UUID `...0008`) included in `builtInPresets`.

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/DictationPresetTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct DictationPresetTests {
    @Test func oldJSONWithoutNewFieldsDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-0000000000AA","name":"Old","isBuiltIn":false,
         "enableFillerRemoval":true,"enableDedup":true,"enableAIFormatting":false,
         "enableCustomDictionary":false,"enableRewrite":false,"aiPrompt":"",
         "rewritePrompt":"","dictionaryEntries":[]}
        """
        let preset = try JSONDecoder().decode(DictationPreset.self, from: Data(json.utf8))
        #expect(preset.output == .insertAtCursor)
        #expect(preset.keepAudio == false)
    }

    @Test func newFieldsRoundTrip() throws {
        var preset = DictationPreset.plain
        preset.output = .logEntry
        preset.keepAudio = true
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(DictationPreset.self, from: data)
        #expect(decoded.output == .logEntry)
        #expect(decoded.keepAudio == true)
    }

    @Test func logPresetIsBuiltIn() {
        let log = DictationPreset.log
        #expect(log.id == UUID(uuidString: "00000000-0000-0000-0000-000000000008"))
        #expect(log.output == .logEntry)
        #expect(log.keepAudio == false)
        #expect(log.excludedFromRotation == true)
        #expect(log.requiresAI == false)
        #expect(DictationPreset.builtInPresets.contains(log))
    }

    @Test func withoutAIKeepsOutputAndAudio() {
        var preset = DictationPreset.polished
        preset.output = .logEntry
        preset.keepAudio = true
        let fallback = preset.withoutAI
        #expect(fallback.requiresAI == false)
        #expect(fallback.output == .logEntry)
        #expect(fallback.keepAudio == true)
        #expect(fallback.enableCustomDictionary == preset.enableCustomDictionary)
        #expect(fallback.id == preset.id)
    }
}
```

- [ ] **Step 2: Run to see it fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/DictationPresetTests 2>&1 | tail -20
```

Expected: build failure, `output` / `log` / `withoutAI` not found.

- [ ] **Step 3: Implement in DictationPreset.swift**

After `enum TrailingCharacter` add:

```swift
/// Where a preset's text goes after post-processing.
enum PresetOutput: String, Codable, CaseIterable, Identifiable {
    /// Typed at the cursor (Accessibility API, clipboard fallback).
    case insertAtCursor
    /// Saved as a Markdown log entry in the library; nothing is typed.
    case logEntry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .insertAtCursor: return "Insert at cursor"
        case .logEntry: return "Save as log entry"
        }
    }
}
```

In `struct DictationPreset` add after `var language: String?`:

```swift
    var output: PresetOutput
    /// Log presets only: also save the recording as `.m4a` next to the entry.
    var keepAudio: Bool
```

Add init parameters after `language: String? = nil`: `output: PresetOutput = .insertAtCursor, keepAudio: Bool = false`, and assign `self.output = output`, `self.keepAudio = keepAudio`.

In `init(from:)` after the `language` line:

```swift
        output = try c.decodeIfPresent(PresetOutput.self, forKey: .output) ?? .insertAtCursor
        keepAudio = try c.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? false
```

Add to the extension:

```swift
    /// Copy with every AI step off. Used when the LLM is unavailable or
    /// refuses the text. Keeps every other field, including `output`, so a
    /// log preset never falls back to typing at the cursor.
    var withoutAI: DictationPreset {
        var copy = self
        copy.enableAIFormatting = false
        copy.enableRewrite = false
        return copy
    }
```

Add the ID and preset next to the others:

```swift
    private static let logID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!

    static let log = DictationPreset(
        id: logID,
        name: "Log",
        isBuiltIn: true,
        enableFillerRemoval: true,
        enableDedup: true,
        enableAIFormatting: false,
        enableCustomDictionary: false,
        enableRewrite: false,
        aiPrompt: "",
        rewritePrompt: "",
        dictionaryEntries: [],
        excludedFromRotation: true,
        output: .logEntry
    )
```

and change `builtInPresets` to `[plain, polished, professional, code, caveman, yoda, emoji, log]`.

- [ ] **Step 4: Replace the memberwise copies**

In `AppCoordinator.swift`, replace the body of `private static func nonAIFallback(from preset: DictationPreset) -> DictationPreset` with `preset.withoutAI` (keep the doc comment).

In `PresetsSettingsView.swift` `duplicatePreset(_:)`, replace the `DictationPreset(...)` construction with:

```swift
        var newPreset = source
        newPreset.id = UUID()
        newPreset.name = "\(source.name) Copy"
        newPreset.isBuiltIn = false
```

`addCustomPreset()` builds a fresh preset; leave it (defaults are insert at cursor). Then grep to confirm no other memberwise copies remain:

```bash
cd /Users/jordi/git/roger/Roger && grep -rn "DictationPreset(" App UI Services Models LLM | grep -v "static let"
```

Expected: only `addCustomPreset` in PresetsSettingsView.

- [ ] **Step 5: Run tests and build**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/DictationPresetTests 2>&1 | tail -20
```

Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger && git add Roger/Models/DictationPreset.swift Roger/App/AppCoordinator.swift Roger/UI/PresetsSettingsView.swift Roger/RogerTests/DictationPresetTests.swift
git commit -m "feat: add an output target to presets and a built-in Log preset"
```

---

### Task 4: LogEntryWriter and audio encoding

**Files:**
- Create: `Roger/Services/LogEntryWriter.swift`
- Create: `Roger/Services/LogAudioEncoder.swift`
- Create: `Roger/RogerTests/LogEntryWriterTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryLayout` (Task 2), `TranscriptFrontmatter` (existing).
- Produces:
  - `struct LogEntry: Sendable { let text: String; let startedAt: Date; let endedAt: Date; let presetName: String; let language: String? }`
  - `enum LogEntryWriter { static func baseName(for: Date) -> String; static func title(for: LogEntry) -> String; static func content(for: LogEntry, audioFileName: String?, generatedAt: Date) -> String; static func uniqueBaseName(_: String, in: URL) -> String; static func write(_: LogEntry, layout: LibraryLayout, audioSamples: [Float]?, encodeAudio: @Sendable ([Float], URL) throws -> Void = LogAudioEncoder.writeM4A) async throws -> URL }`
  - `enum LogAudioEncoder { static let sampleRate: Double = 16000; static func writeM4A(samples: [Float], to url: URL) throws }`

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/LogEntryWriterTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Roger

struct LogEntryWriterTests {
    private func date(_ h: Int, _ m: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 13; c.hour = h; c.minute = m; c.second = s
        return Calendar.current.date(from: c)!
    }

    private func entry(_ text: String = "Called the supplier about the delayed shipment today") -> LogEntry {
        LogEntry(text: text, startedAt: date(14, 32, 5), endedAt: date(14, 32, 38), presetName: "Log", language: "de")
    }

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func baseNameUsesSeconds() {
        #expect(LogEntryWriter.baseName(for: date(14, 32, 5)) == "2026-10-13 14-32-05")
    }

    @Test func titleUsesFirstSixWords() {
        #expect(LogEntryWriter.title(for: entry()) == "Log 2026-10-13 14:32 - Called the supplier about the delayed")
    }

    @Test func titleStripsTrailingPunctuationAndHandlesShortText() {
        #expect(LogEntryWriter.title(for: entry("Done, finally.")) == "Log 2026-10-13 14:32 - Done, finally")
        #expect(LogEntryWriter.title(for: entry("   ")) == "Log 2026-10-13 14:32")
    }

    @Test func contentHasFrontmatterAndBody() {
        let md = LogEntryWriter.content(for: entry(), audioFileName: nil, generatedAt: date(14, 32, 41))
        #expect(md.hasPrefix("---\ntype: source\n"))
        #expect(md.contains("title: \"Log 2026-10-13 14:32 - Called the supplier about the delayed\"\n"))
        #expect(md.contains("description: \"Log entry recorded with Roger on 2026-10-13 at 14:32.\"\n"))
        #expect(md.contains("tags: [log]\n"))
        #expect(md.contains("source_date: 2026-10-13\n"))
        #expect(md.contains("temporal_confidence: explicit\n"))
        #expect(md.contains("status: stable\n"))
        #expect(md.contains("duration_seconds: 33\n"))
        #expect(md.contains("preset: \"Log\"\n"))
        #expect(md.contains("language: \"de\"\n"))
        #expect(!md.contains("sources:"))
        #expect(md.hasSuffix("---\n\n# Log 2026-10-13 14:32\n\nCalled the supplier about the delayed shipment today\n"))
    }

    @Test func contentListsAudioWhenKept() {
        let md = LogEntryWriter.content(for: entry(), audioFileName: "2026-10-13 14-32-05.m4a", generatedAt: date(14, 32, 41))
        #expect(md.contains("sources:\n  - { id: audio, resource: \"2026-10-13 14-32-05.m4a\" }\n"))
    }

    @Test func contentOmitsUnknownLanguage() {
        let e = LogEntry(text: "x", startedAt: date(9, 0, 0), endedAt: date(9, 0, 2), presetName: "Log", language: nil)
        #expect(!LogEntryWriter.content(for: e, audioFileName: nil, generatedAt: date(9, 0, 3)).contains("language:"))
    }

    @Test func uniqueBaseNameSkipsTakenMdAndM4a() throws {
        let folder = try tempRoot()
        let base = "2026-10-13 14-32-05"
        #expect(LogEntryWriter.uniqueBaseName(base, in: folder) == base)
        try Data().write(to: folder.appendingPathComponent("\(base).md"))
        #expect(LogEntryWriter.uniqueBaseName(base, in: folder) == "\(base) 1")
        try Data().write(to: folder.appendingPathComponent("\(base) 1.m4a"))
        #expect(LogEntryWriter.uniqueBaseName(base, in: folder) == "\(base) 2")
    }

    @Test func writePutsEntryInMonthFolder() async throws {
        let root = try tempRoot()
        let url = try await LogEntryWriter.write(entry(), layout: LibraryLayout(root: root), audioSamples: nil)
        #expect(url.path == root.appendingPathComponent("Logs/2026/10/2026-10-13 14-32-05.md").path)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# Log 2026-10-13 14:32"))
    }

    @Test func writeDoesNotOverwriteSameSecond() async throws {
        let root = try tempRoot()
        let layout = LibraryLayout(root: root)
        let first = try await LogEntryWriter.write(entry(), layout: layout, audioSamples: nil)
        let second = try await LogEntryWriter.write(entry(), layout: layout, audioSamples: nil)
        #expect(first != second)
        #expect(second.lastPathComponent == "2026-10-13 14-32-05 1.md")
    }

    @Test func writeKeepsAudio() async throws {
        let root = try tempRoot()
        let samples = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000)) * 0.3 }
        let url = try await LogEntryWriter.write(entry(), layout: LibraryLayout(root: root), audioSamples: samples)
        let audio = url.deletingPathExtension().appendingPathExtension("m4a")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        let file = try AVAudioFile(forReading: audio)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 1.0) < 0.2)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("id: audio"))
    }

    @Test func failedAudioStillWritesEntryWithoutSources() async throws {
        struct Boom: Error {}
        let root = try tempRoot()
        let url = try await LogEntryWriter.write(
            entry(), layout: LibraryLayout(root: root), audioSamples: [0, 0.1, 0.2],
            encodeAudio: { _, target in
                try Data("partial".utf8).write(to: target)
                throw Boom()
            }
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("sources:"))
        let audio = url.deletingPathExtension().appendingPathExtension("m4a")
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func unwritableRootThrows() async throws {
        let root = try tempRoot()
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        // A regular file where the root folder should be: folder creation fails.
        await #expect(throws: (any Error).self) {
            _ = try await LogEntryWriter.write(entry(), layout: LibraryLayout(root: blocker), audioSamples: nil)
        }
    }
}
```

- [ ] **Step 2: Run to see it fail**

Generate the project first is not needed yet (no new source files). Run:

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LogEntryWriterTests 2>&1 | tail -20
```

Expected: build failure, `LogEntry` not found. (If the new test file is not part of the target yet, run `xcodegen generate` and restore the entitlements first.)

- [ ] **Step 3: Implement LogAudioEncoder**

`Roger/Services/LogAudioEncoder.swift`:

```swift
import AVFoundation
import Foundation

/// Encodes a dictation buffer (16 kHz mono Float32, as captured by
/// `AudioCaptureService`) to an AAC `.m4a` file.
enum LogAudioEncoder {
    static let sampleRate: Double = 16000

    enum EncodeError: Error {
        case bufferUnavailable
    }

    static func writeM4A(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw EncodeError.bufferUnavailable }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // If AVAudioFile rejects these settings at 16 kHz, drop the
        // AVEncoderBitRateKey line and let the encoder pick the bit rate.
        // The file is closed when `file` goes out of scope at the end of this function.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
```

- [ ] **Step 4: Implement LogEntryWriter**

`Roger/Services/LogEntryWriter.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LogEntryWriter")

/// One spoken log entry, ready to be written.
struct LogEntry: Sendable {
    let text: String
    let startedAt: Date
    let endedAt: Date
    let presetName: String
    /// ISO code when known (preset pin or detected), else nil.
    let language: String?
}

/// Writes log entries as OKF Markdown files into
/// `<library>/Logs/YYYY/MM/<yyyy-MM-dd HH-mm-ss>.md`, optionally with the
/// recording as `.m4a` next to it. File names never change after writing,
/// so paths handed to agents stay valid.
enum LogEntryWriter {
    /// Number of words from the text that go into the title.
    static let titleWordCount = 6

    static func baseName(for date: Date) -> String {
        formatter("yyyy-MM-dd HH-mm-ss").string(from: date)
    }

    static func title(for entry: LogEntry) -> String {
        let heading = "Log \(displayTime(entry.startedAt))"
        let words = entry.text.split(whereSeparator: \.isWhitespace).prefix(titleWordCount)
        var snippet = words.joined(separator: " ")
        while let last = snippet.last, ",.;:!?".contains(last) {
            snippet.removeLast()
        }
        return snippet.isEmpty ? heading : "\(heading) - \(snippet)"
    }

    static func content(for entry: LogEntry, audioFileName: String?, generatedAt: Date) -> String {
        let time = displayTime(entry.startedAt)
        let parts = time.split(separator: " ")
        var sources: [TranscriptFrontmatter.Source] = []
        if let audioFileName {
            sources.append(.init(id: "audio", resource: audioFileName))
        }
        var fm = TranscriptFrontmatter(
            title: title(for: entry),
            description: "Log entry recorded with Roger on \(parts[0]) at \(parts[1]).",
            tags: ["log"],
            generatedAt: generatedAt,
            sourceDate: entry.startedAt,
            temporalConfidence: .explicit,
            sources: sources,
            status: "stable"
        )
        fm.add("started_at", date: entry.startedAt)
        fm.add("ended_at", date: entry.endedAt)
        fm.add("duration_seconds", Int(entry.endedAt.timeIntervalSince(entry.startedAt).rounded()))
        fm.add("preset", entry.presetName)
        if let language = entry.language {
            fm.add("language", language)
        }
        let body = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.render() + "# Log \(time)\n\n\(body)\n"
    }

    /// `base`, `base 1`, `base 2` … until neither `.md` nor `.m4a` exists.
    static func uniqueBaseName(_ base: String, in folder: URL) -> String {
        let fm = FileManager.default
        func taken(_ name: String) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent("\(name).md").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("\(name).m4a").path)
        }
        var candidate = base
        var suffix = 1
        while taken(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Writes the entry and returns the `.md` URL. Audio is encoded first,
    /// off the main actor; if that fails the entry is still written, without
    /// `sources`, and any partial `.m4a` is removed.
    static func write(
        _ entry: LogEntry,
        layout: LibraryLayout,
        audioSamples: [Float]?,
        encodeAudio: @escaping @Sendable ([Float], URL) throws -> Void = LogAudioEncoder.writeM4A
    ) async throws -> URL {
        let folder = layout.monthFolder(.logs, for: entry.startedAt)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = uniqueBaseName(baseName(for: entry.startedAt), in: folder)
        let markdownURL = folder.appendingPathComponent("\(name).md")

        var audioFileName: String?
        if let samples = audioSamples, !samples.isEmpty {
            let audioURL = folder.appendingPathComponent("\(name).m4a")
            do {
                try await Task.detached(priority: .userInitiated) {
                    try encodeAudio(samples, audioURL)
                }.value
                audioFileName = audioURL.lastPathComponent
            } catch {
                logger.error("Log audio encode failed: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        let markdown = content(for: entry, audioFileName: audioFileName, generatedAt: .now)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        return markdownURL
    }

    // MARK: - Helpers

    /// `yyyy-MM-dd HH:mm` in local time.
    private static func displayTime(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }
}
```

- [ ] **Step 5: Generate, run tests**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LogEntryWriterTests 2>&1 | tail -30
```

Expected: all 12 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger && git add Roger/Services/LogEntryWriter.swift Roger/Services/LogAudioEncoder.swift Roger/RogerTests/LogEntryWriterTests.swift Roger/Roger.xcodeproj
git commit -m "feat: write log entries as Markdown files with optional audio"
```

---

### Task 5: Save log entries from the dictation pipeline, indicator and popover

**Files:**
- Modify: `Roger/App/AppCoordinator.swift` (`stopDictation` ~line 266, `runPipeline` ~line 332)
- Modify: `Roger/UI/FloatingPanel.swift` (accents ~line 90, `accent` ~line 113, body label ~line 252, waveform ZStack ~line 147)
- Modify: `Roger/UI/MenuBarView.swift` (`LastDictationCard` ~line 48 and ~line 443)

**Interfaces:**
- Consumes: `PresetOutput`, `DictationPreset.withoutAI` (Task 3), `LogEntry`, `LogEntryWriter.write` (Task 4), `AppState.libraryLayout`, `AppState.lastLogEntryURL` (Task 2).
- Produces: `AppCoordinator.showsLogSaved: Bool` (observable, true for 1.5 s after a log entry is saved).

This task is UI and orchestration. It is verified by build and manual checks, not unit tests.

- [ ] **Step 1: Pass recording data into runPipeline**

In `stopDictation()`:
- Before `recordingStartTime = nil`, capture `let endedAt = Date()` and `let startedAt = recordingStartTime ?? endedAt.addingTimeInterval(-duration)`.
- Change the call to:

```swift
            await self.runPipeline(audioSeconds: duration, startedAt: startedAt, endedAt: endedAt, samples: samples) {
```

Change the signature:

```swift
    private func runPipeline(
        audioSeconds: Double,
        startedAt: Date,
        endedAt: Date,
        samples: [Float]?,
        transcribe: @escaping () async throws -> TranscriptionEngine.TranscriptionResult
    ) async {
```

- [ ] **Step 2: Branch to the log in runPipeline**

In the guardrail `catch LLMError.guardrailViolation` block, after `let safeText = ...`, insert before `appState.lastTranscription = safeText`:

```swift
                        if activePreset.output == .logEntry {
                            // A file surprises nobody: save the non-AI text.
                            await saveLogEntry(safeText, preset: activePreset, startedAt: startedAt, endedAt: endedAt,
                                               language: result.detectedLanguage ?? activePreset.language, samples: samples)
                            return
                        }
```

After the AI/non-AI post-processing block (right after `let llmMs = ...`), before `appState.dictationState = .inserting`, insert:

```swift
            if activePreset.output == .logEntry {
                await saveLogEntry(processedText, preset: activePreset, startedAt: startedAt, endedAt: endedAt,
                                   language: result.detectedLanguage ?? activePreset.language, samples: samples)
                return
            }
```

After the insert path's `appState.lastTranscription = processedText`, add `appState.lastLogEntryURL = nil`.

- [ ] **Step 3: Add saveLogEntry and the saved state**

Add to `AppCoordinator` properties (near `activeRecordingPresetID`):

```swift
    /// True for a short moment after a log entry was saved; the floating
    /// indicator shows "Logged" while it is set.
    private(set) var showsLogSaved = false
    private var logSavedGeneration = 0
```

Add the method after `runPipeline`:

```swift
    /// Writes a log entry instead of typing. On failure the text stays in
    /// `lastTranscription` so nothing is lost.
    private func saveLogEntry(
        _ text: String,
        preset: DictationPreset,
        startedAt: Date,
        endedAt: Date,
        language: String?,
        samples: [Float]?
    ) async {
        appState.lastTranscription = text
        let entry = LogEntry(text: text, startedAt: startedAt, endedAt: endedAt, presetName: preset.name, language: language)
        do {
            let url = try await LogEntryWriter.write(
                entry,
                layout: appState.libraryLayout,
                audioSamples: preset.keepAudio ? samples : nil
            )
            appState.lastLogEntryURL = url
            logger.notice("Log entry saved: \(url.path, privacy: .public)")
        } catch {
            logger.error("Log entry write failed: \(error.localizedDescription, privacy: .public)")
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
        showsLogSaved = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard generation == logSavedGeneration else { return }
        showsLogSaved = false
        // A new dictation may have started meanwhile; it owns the panel then.
        if appState.dictationState == .idle {
            floatingPanel.hide()
        }
    }
```

In `startDictation`, right after `floatingPanel.show(coordinator: self)`, add `showsLogSaved = false` and `logSavedGeneration += 1` so a new recording cancels the pending hide.

Note: `floatingPanel.show` returns early when the panel already exists; that is fine because the panel content is driven by observed state.

- [ ] **Step 4: Indicator colours and labels**

In `FloatingPanel.swift` (`FloatingIndicatorContent`):

1. Next to the other accents add:

```swift
    private static let logAccent = Color(red: 0.2, green: 1.0, blue: 0.45)
```

and update the comment above the accents to mention "electric green for log entries".

2. Add:

```swift
    /// Log presets save to a file instead of typing; shown in green.
    private var isLogMode: Bool {
        coordinator.showsLogSaved || activePreset?.output == .logEntry
    }

    private var statusLabel: String {
        if coordinator.showsLogSaved { return "Logged" }
        if isLogMode { return isListening ? "Logging" : "Saving" }
        return isListening ? "Listening" : "Thinking"
    }
```

3. In `accent`, after the meeting line add `if isLogMode { return Self.logAccent }`.

4. Replace `Text(isListening ? "Listening" : "Thinking")` with `Text(statusLabel)`.

5. In the waveform `ZStack`, show a checkmark when saved:

```swift
                if coordinator.showsLogSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                        .transition(.opacity)
                } else if isListening {
                    PanelWaveform()
                        .transition(.opacity)
                } else {
                    SweepBar()
                        .transition(.opacity)
                }
```

The waveform itself must stay unchanged while logging.

- [ ] **Step 5: Popover: reveal the last log entry**

In `MenuBarView.swift`, change `LastDictationCard(text: text)` to `LastDictationCard(text: text, logURL: coordinator.appState.lastLogEntryURL)`. In `LastDictationCard` add `let logURL: URL?` and, below the existing card button (wrap both in a `VStack(alignment: .leading, spacing: 4)` if needed), add:

```swift
        if let logURL {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([logURL])
            } label: {
                Label("Saved to log - Show in Finder", systemImage: "book.closed")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
```

Make sure `AppKit` is imported in MenuBarView.swift (it uses `NSWorkspace` already elsewhere; check).

- [ ] **Step 6: Build and run the whole test suite**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "error|warning: .*(LogEntry|saveLogEntry|FloatingPanel)|BUILD" | tail -20
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`, `TEST SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger && git add Roger/App/AppCoordinator.swift Roger/UI/FloatingPanel.swift Roger/UI/MenuBarView.swift
git commit -m "feat: save log presets as log entries instead of typing"
```

Manual check (for the human, listed in the final report): bind Log to Caps+Option, record, see green "Logging", then "Logged", and the file in `~/Documents/Roger/Logs/YYYY/MM/`.

---

### Task 6: Meetings in the library, recovery scan and Keep audio

**Files:**
- Create: `Roger/Services/MeetingRecording/MeetingSessionScanner.swift`
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (`start` ~line 92, `unfinalisedSessions` ~line 201, `resolvedRecordingsFolder` ~line 404, `runFinalisationPipeline` ~line 560-620)
- Modify: `Roger/Services/MeetingRecording/MeetingTranscriptWriter.swift` (`Metadata`, `buildContent` sources)
- Modify: `Roger/App/AppState.swift` (remove `meetingRecordingsFolder`)
- Modify: `Roger/UI/RecordingsSettingsView.swift`
- Create: `Roger/RogerTests/MeetingSessionScannerTests.swift`

**Interfaces:**
- Consumes: `AppState.libraryLayout`, `AppState.extraScanFolders`, `AppState.keepMeetingAudio` (Task 2).
- Produces:
  - `enum MeetingSessionScanner { static func isSessionFolder(_ url: URL) -> Bool; static func sessionFolders(in folder: URL, maxDepth: Int) -> [URL]; static func allSessionFolders(layout: LibraryLayout, extraFolders: [URL]) -> [URL] }`
  - `MeetingTranscriptWriter.Metadata.audioKept: Bool`

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/MeetingSessionScannerTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct MeetingSessionScannerTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(_ folder: URL, files: [String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data().write(to: folder.appendingPathComponent(name))
        }
    }

    @Test func recognisesSessionFolders() throws {
        let root = try tempRoot()
        try makeSession(root.appendingPathComponent("a"), files: ["mic-001.caf"])
        try makeSession(root.appendingPathComponent("b"), files: ["transcript.md"])
        try makeSession(root.appendingPathComponent("c"), files: ["notes.txt"])
        #expect(MeetingSessionScanner.isSessionFolder(root.appendingPathComponent("a")))
        #expect(MeetingSessionScanner.isSessionFolder(root.appendingPathComponent("b")))
        #expect(!MeetingSessionScanner.isSessionFolder(root.appendingPathComponent("c")))
    }

    @Test func findsNestedSessionsInLibrary() throws {
        let root = try tempRoot()
        let layout = LibraryLayout(root: root)
        let meetings = layout.kindFolder(.meetings)
        try makeSession(meetings.appendingPathComponent("2026/10/2026-10-13 09-00"), files: ["mic-001.caf"])
        try makeSession(meetings.appendingPathComponent("2026/09/2026-09-01 10-00"), files: ["transcript.md", "mic.m4a"])
        let found = MeetingSessionScanner.sessionFolders(in: meetings, maxDepth: 3).map(\.lastPathComponent).sorted()
        #expect(found == ["2026-09-01 10-00", "2026-10-13 09-00"])
    }

    @Test func doesNotDescendIntoSessions() throws {
        let root = try tempRoot()
        let session = root.appendingPathComponent("2026-10-13 09-00")
        try makeSession(session, files: ["transcript.md"])
        try makeSession(session.appendingPathComponent("nested"), files: ["mic-001.caf"])
        #expect(MeetingSessionScanner.sessionFolders(in: root, maxDepth: 3) .map(\.lastPathComponent) == ["2026-10-13 09-00"])
    }

    @Test func respectsMaxDepth() throws {
        let root = try tempRoot()
        try makeSession(root.appendingPathComponent("x/y/z/s"), files: ["mic-001.caf"])
        #expect(MeetingSessionScanner.sessionFolders(in: root, maxDepth: 3).isEmpty)
        #expect(MeetingSessionScanner.sessionFolders(in: root, maxDepth: 4).count == 1)
    }

    @Test func combinesLibraryAndLegacyFolders() throws {
        let root = try tempRoot()
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        try makeSession(layout.kindFolder(.meetings).appendingPathComponent("2026/10/new"), files: ["mic-001.caf"])
        let legacy = root.appendingPathComponent("Roger Recordings")
        try makeSession(legacy.appendingPathComponent("old"), files: ["system-001.caf"])
        let names = MeetingSessionScanner.allSessionFolders(layout: layout, extraFolders: [legacy, root.appendingPathComponent("missing")])
            .map(\.lastPathComponent).sorted()
        #expect(names == ["new", "old"])
    }
}
```

- [ ] **Step 2: Implement the scanner**

`Roger/Services/MeetingRecording/MeetingSessionScanner.swift`:

```swift
import Foundation

/// Finds meeting session folders on disk. Sessions live at
/// `<library>/Meetings/YYYY/MM/<session>/` and, for older installs, directly
/// inside extra scan folders such as `~/Documents/Roger Recordings/`.
enum MeetingSessionScanner {
    /// A folder is a session when it holds audio chunks, archives, markers
    /// or a transcript.
    static func isSessionFolder(_ url: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { name in
            name.hasSuffix(".caf")
                || name == "transcript.md"
                || name == "markers.json"
                || name == "mic.m4a"
                || name == "system.m4a"
        }
    }

    /// Session folders at most `maxDepth` levels below `folder`. Does not
    /// look inside a session folder once found.
    static func sessionFolders(in folder: URL, maxDepth: Int) -> [URL] {
        guard maxDepth > 0 else { return [] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [URL] = []
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if isSessionFolder(child) {
                result.append(child)
            } else {
                result.append(contentsOf: sessionFolders(in: child, maxDepth: maxDepth - 1))
            }
        }
        return result
    }

    /// All sessions: the library's `Meetings/YYYY/MM/` tree plus sessions
    /// stored directly in each extra folder.
    static func allSessionFolders(layout: LibraryLayout, extraFolders: [URL]) -> [URL] {
        var result = sessionFolders(in: layout.kindFolder(.meetings), maxDepth: 3)
        for folder in extraFolders {
            result.append(contentsOf: sessionFolders(in: folder, maxDepth: 1))
        }
        return result
    }
}
```

- [ ] **Step 3: Generate, run tests**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/MeetingSessionScannerTests 2>&1 | tail -20
```

Expected: 5 tests pass.

- [ ] **Step 4: Record meetings into the library**

In `MeetingRecordingService.swift`:

1. In `start()`, replace `let parent = resolvedRecordingsFolder()` and `session = try MeetingSession.create(in: parent)` with:

```swift
        let startedAt = Date()
        let parent = appState.libraryLayout.monthFolder(.meetings, for: startedAt)
```

and `session = try MeetingSession.create(in: parent, startedAt: startedAt)`.

2. Replace the body of `unfinalisedSessions()` so it iterates `MeetingSessionScanner.allSessionFolders(layout: appState.libraryLayout, extraFolders: appState.extraScanFolders)` instead of the direct children of `resolvedRecordingsFolder()`. Keep the existing per-folder logic (CAF present, no transcript.md, start date from markers.json or creation date).

3. Delete `resolvedRecordingsFolder()`.

- [ ] **Step 5: Keep audio after transcription**

In `MeetingTranscriptWriter.Metadata` add `let audioKept: Bool` (after `systemPresent`, with a doc comment "False when the audio files are deleted after the transcript is written; `sources` is left out then."). In `buildContent`, wrap the two `sources.append` calls in `if metadata.audioKept { ... }`.

In `runFinalisationPipeline`, pass `audioKept: appState.keepMeetingAudio` when building `metadata`. After the successful `MeetingTranscriptWriter.write(...)` call (inside the success path, never before it), add:

```swift
        if !appState.keepMeetingAudio {
            // Only after the transcript exists: the CAF chunks are already gone,
            // so these archives were the last copy of the audio.
            try? FileManager.default.removeItem(at: micArchive)
            try? FileManager.default.removeItem(at: systemArchive)
        }
```

Grep for any other `Metadata(` construction and add `audioKept:` there too:

```bash
cd /Users/jordi/git/roger/Roger && grep -rn "MeetingTranscriptWriter.Metadata(" .
```

- [ ] **Step 6: Remove meetingRecordingsFolder and update Recordings settings**

In `AppState.swift` delete the `meetingRecordingsFolder` property and its `init` lines. (`legacyMeetingRecordingsFolder` from Task 2 keeps reading the old key.)

In `RecordingsSettingsView.swift`:

1. Replace the "Output Folder" card with a "Library Folder" card bound to `state.libraryRoot`:
   - Caption: "Roger saves log entries, meetings and file transcripts here, in the folders Logs, Meetings and Transcripts, sorted by year and month."
   - Path label of `state.libraryLayout.root.path`, "Default" badge when `state.libraryRoot == nil`, "Choose…" (folder picker sets `state.libraryRoot`), "Reset" when not default, "Reveal in Finder" (creates the root folder if missing, then reveals it).
   - Small caption: "Existing files stay where they are when the folder changes."
   - Toggle row "Keep audio after transcription" bound to `state.keepMeetingAudio`, with caption "When off, mic.m4a and system.m4a are deleted once the meeting transcript is written."
   - If `state.extraScanFolders` is not empty: a list titled "Older folders" with each path and a "Remove" button that removes it from `state.extraScanFolders`. Caption: "Roger still finds meetings in these folders."
2. Delete `defaultRecordingsFolder()`, `resolvedFolder()`, `folderLabel` and `isUsingDefaultFolder` if no longer used.
3. In `refresh()`, build rows from `MeetingSessionScanner.allSessionFolders(layout: coordinator.appState.libraryLayout, extraFolders: coordinator.appState.extraScanFolders)` instead of `contentsOfDirectory`. Date: parse the folder name with `MeetingSession.folderNameFormatter`, fall back to the creation date. Change `.onChange(of: state.meetingRecordingsFolder)` to `.onChange(of: state.libraryRoot)`.

- [ ] **Step 7: Build and test**

```bash
cd /Users/jordi/git/roger/Roger && grep -rn "meetingRecordingsFolder\|resolvedRecordingsFolder" App UI Services Models
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "error|BUILD" | tail -10
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: grep prints only `AppState.swift` lines for `legacyMeetingRecordingsFolder` (the key string "meetingRecordingsFolder"); `BUILD SUCCEEDED`; `TEST SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
cd /Users/jordi/git/roger && git add -A Roger/Services/MeetingRecording Roger/App/AppState.swift Roger/UI/RecordingsSettingsView.swift Roger/RogerTests/MeetingSessionScannerTests.swift Roger/Roger.xcodeproj
git commit -m "feat: record meetings into the library and make keeping their audio optional"
```

---

### Task 7: File transcripts in the library and the external list

**Files:**
- Create: `Roger/Services/ExternalTranscriptRegistry.swift`
- Modify: `Roger/Services/TranscriptOutputWriter.swift`
- Modify: `Roger/App/AppState.swift` (`FileTranscriptOutputLocation`, remove `fileTranscriptOutputFolder`)
- Modify: `Roger/App/AppCoordinator.swift` (`TranscriptOutputWriter.write` call ~line 693)
- Modify: `Roger/UI/SettingsView.swift` (`FileTranscriptionSettingsView` ~line 570-690)
- Create: `Roger/RogerTests/ExternalTranscriptRegistryTests.swift`
- Create: `Roger/RogerTests/TranscriptOutputWriterTests.swift`

**Interfaces:**
- Consumes: `LibraryLayout` (Task 2).
- Produces:
  - `enum FileTranscriptOutputLocation { case library, alongsideSource }` (rawValues `"library"`, `"alongsideSource"`; stored `"customFolder"` falls back to `.library`; default `.library`).
  - `TranscriptOutputWriter.write(source: URL, location: FileTranscriptOutputLocation, layout: LibraryLayout, now: Date = .now, content: (URL) -> String) throws -> URL`
  - `struct ExternalTranscriptRegistry { let fileURL: URL; static var standard: ExternalTranscriptRegistry; func add(_ url: URL) throws; func existingFiles() -> [URL] }`

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/ExternalTranscriptRegistryTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct ExternalTranscriptRegistryTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addsAndListsWithoutDuplicates() throws {
        let root = try tempRoot()
        let registry = ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("sub/external-transcripts.json"))
        let file = root.appendingPathComponent("talk.mp4.md")
        try Data("x".utf8).write(to: file)
        try registry.add(file)
        try registry.add(file)
        #expect(registry.existingFiles() == [file.standardizedFileURL])
    }

    @Test func prunesMissingFiles() throws {
        let root = try tempRoot()
        let registry = ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("external-transcripts.json"))
        let kept = root.appendingPathComponent("a.md")
        let gone = root.appendingPathComponent("b.md")
        try Data().write(to: kept)
        try Data().write(to: gone)
        try registry.add(kept)
        try registry.add(gone)
        try FileManager.default.removeItem(at: gone)
        #expect(registry.existingFiles() == [kept.standardizedFileURL])
        // The pruned list was saved.
        let fresh = ExternalTranscriptRegistry(fileURL: registry.fileURL)
        #expect(fresh.existingFiles() == [kept.standardizedFileURL])
    }

    @Test func missingRegistryIsEmpty() throws {
        let root = try tempRoot()
        #expect(ExternalTranscriptRegistry(fileURL: root.appendingPathComponent("none.json")).existingFiles().isEmpty)
    }
}
```

`Roger/RogerTests/TranscriptOutputWriterTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct TranscriptOutputWriterTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func libraryLocationUsesTranscriptsMonthFolder() throws {
        let root = try tempRoot()
        let source = root.appendingPathComponent("talk.mp4")
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 13; c.hour = 12
        let now = Calendar.current.date(from: c)!
        let url = try TranscriptOutputWriter.write(
            source: source, location: .library, layout: LibraryLayout(root: root.appendingPathComponent("Lib")), now: now
        ) { _ in "body" }
        #expect(url.path == root.appendingPathComponent("Lib/Transcripts/2026/10/talk.mp4.md").path)
    }

    @Test func alongsideSourceWritesNextToSource() throws {
        let root = try tempRoot()
        let source = root.appendingPathComponent("talk.mp4")
        let url = try TranscriptOutputWriter.write(
            source: source, location: .alongsideSource, layout: LibraryLayout(root: root.appendingPathComponent("Lib"))
        ) { _ in "body" }
        #expect(url.path == root.appendingPathComponent("talk.mp4.md").path)
    }

    @Test func legacyCustomFolderValueFallsBackToLibrary() {
        #expect(FileTranscriptOutputLocation(rawValue: "customFolder") == nil)
        #expect(FileTranscriptOutputLocation.allCases == [.library, .alongsideSource])
    }
}
```

- [ ] **Step 2: Implement the registry**

`Roger/Services/ExternalTranscriptRegistry.swift`:

```swift
import Foundation

/// Remembers transcripts Roger wrote outside the library ("next to the
/// source file"), so the library can still list them. Stored as JSON in
/// Application Support. Files that no longer exist are dropped on read.
struct ExternalTranscriptRegistry {
    let fileURL: URL

    private struct Stored: Codable {
        var version = 1
        var paths: [String]
    }

    static var standard: ExternalTranscriptRegistry {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ExternalTranscriptRegistry(
            fileURL: support.appendingPathComponent("Roger", isDirectory: true)
                .appendingPathComponent("external-transcripts.json")
        )
    }

    func add(_ url: URL) throws {
        var paths = load()
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
        try save(paths)
    }

    /// Paths that still exist. Saves the list again when some were missing.
    func existingFiles() -> [URL] {
        let paths = load()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.count != paths.count {
            try? save(existing)
        }
        return existing.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [] }
        return stored.paths
    }

    private func save(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Stored(paths: paths)).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 3: Change the location enum and the writer**

In `AppState.swift`:

```swift
enum FileTranscriptOutputLocation: String, CaseIterable, Identifiable, Codable {
    /// `<library>/Transcripts/YYYY/MM/`.
    case library
    case alongsideSource

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .library: return "Roger library"
        case .alongsideSource: return "Next to the source file"
        }
    }
}
```

In `init()`, the default becomes `?? .library` (a stored `"customFolder"` no longer decodes and so becomes `.library`). Delete the `fileTranscriptOutputFolder` property and its `init` lines (`legacyFileTranscriptFolder` keeps reading the key).

In `TranscriptOutputWriter.swift`, change `write` to:

```swift
    static func write(
        source: URL,
        location: FileTranscriptOutputLocation,
        layout: LibraryLayout,
        now: Date = .now,
        content: (URL) -> String
    ) throws -> URL {
        let baseDir: URL
        switch location {
        case .alongsideSource:
            baseDir = source.deletingLastPathComponent()
        case .library:
            baseDir = layout.monthFolder(.transcripts, for: now)
        }
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            throw WriteError.destinationNotWritable(baseDir)
        }
        let candidate = baseDir.appendingPathComponent("\(source.lastPathComponent).md")
        let destination = uniqueDestination(for: candidate)
        do {
            try content(destination).write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.destinationNotWritable(destination)
        }
        return destination
    }
```

Update the doc comment above it ("next to the source or into the library's Transcripts folder").

In `AppCoordinator.swift` change the call to `TranscriptOutputWriter.write(source: job.sourceURL, location: appState.fileTranscriptOutputLocation, layout: appState.libraryLayout) { ... }` and after it:

```swift
            if appState.fileTranscriptOutputLocation == .alongsideSource {
                do {
                    try ExternalTranscriptRegistry.standard.add(outputURL)
                } catch {
                    logger.warning("Could not remember transcript path: \(error.localizedDescription, privacy: .public)")
                }
            }
```

- [ ] **Step 4: Update the file transcription settings**

In `FileTranscriptionSettingsView` (SettingsView.swift):
- Caption: "Drop an audio or video file on Roger's menu bar icon. The transcript is saved as a Markdown file."
- Remove the custom-folder row, `showingFolderPicker`, the `.fileImporter` and `folderLabel`.
- When `.library` is selected, show a caption with `state.libraryLayout.kindFolder(.transcripts).path` + "/YYYY/MM" (`.font(.caption2)`, `.foregroundStyle(.secondary)`).
- `filenameRuleText`: "Saved as <filename>.md. Existing files are never overwritten. Roger adds -1, -2 and so on."

- [ ] **Step 5: Generate, build, test**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
grep -rn "fileTranscriptOutputFolder\|customFolder" App UI Services Models
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: grep shows only the `legacyFileTranscriptFolder` key string in AppState.swift; `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger && git add -A Roger/Services Roger/App Roger/UI/SettingsView.swift Roger/RogerTests Roger/Roger.xcodeproj
git commit -m "feat: save file transcripts into the library by default"
```

---

### Task 8: One-time migration of old meetings

**Files:**
- Create: `Roger/Services/LibraryMigration.swift`
- Modify: `Roger/App/AppCoordinator.swift` (new `runLibraryMigrationIfNeeded()`)
- Modify: `Roger/App/RogerApp.swift` (call it in `applicationDidFinishLaunching`, after the XCTest guard)
- Create: `Roger/RogerTests/LibraryMigrationTests.swift`

**Interfaces:**
- Consumes: `LibraryLayout`, `MeetingSessionScanner`, `MeetingSession.folderNameFormatter`, `AppState.legacyMeetingRecordingsFolder`, `AppState.legacyFileTranscriptFolder`, `AppState.extraScanFolders`, `AppState.libraryMigrationDone`.
- Produces:
  - `enum LibraryMigration { struct Move: Equatable { let source: URL; let destinationFolder: URL }; static func sessionDate(for folder: URL) -> Date?; static func plan(sessionFolders: [URL], layout: LibraryLayout) -> [Move]; static func execute(_ moves: [Move]) -> (moved: [URL], failed: [Move]) }`
  - `AppCoordinator.runLibraryMigrationIfNeeded()`

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/LibraryMigrationTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryMigrationTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RogerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: folder.appendingPathComponent("transcript.md"))
    }

    @Test func monthComesFromFolderName() throws {
        let root = try tempRoot()
        let old = root.appendingPathComponent("Roger Recordings/2026-03-05 09-30")
        try makeSession(old)
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let moves = LibraryMigration.plan(sessionFolders: [old], layout: layout)
        #expect(moves == [.init(source: old, destinationFolder: layout.kindFolder(.meetings).appendingPathComponent("2026/03"))])
    }

    @Test func suffixedFolderNameStillParses() {
        let url = URL(fileURLWithPath: "/x/2026-10-13 09-00 1")
        let date = LibraryMigration.sessionDate(for: url)
        #expect(date.map { Calendar.current.component(.month, from: $0) } == 10)
    }

    @Test func unparsableNameFallsBackToCreationDate() throws {
        let root = try tempRoot()
        let old = root.appendingPathComponent("Weekly sync")
        try makeSession(old)
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let moves = LibraryMigration.plan(sessionFolders: [old], layout: layout)
        let now = Date()
        #expect(moves.first?.destinationFolder == layout.monthFolder(.meetings, for: now))
    }

    @Test func executeMovesAndAvoidsCollisions() throws {
        let root = try tempRoot()
        let layout = LibraryLayout(root: root.appendingPathComponent("Roger"))
        let old = root.appendingPathComponent("Roger Recordings/2026-10-13 09-00")
        try makeSession(old)
        let existing = layout.kindFolder(.meetings).appendingPathComponent("2026/10/2026-10-13 09-00")
        try makeSession(existing)

        let result = LibraryMigration.execute(LibraryMigration.plan(sessionFolders: [old], layout: layout))
        #expect(result.failed.isEmpty)
        #expect(result.moved.map(\.lastPathComponent) == ["2026-10-13 09-00 1"])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("transcript.md").path))
    }

    @Test func executeReportsFailures() throws {
        let root = try tempRoot()
        let missing = root.appendingPathComponent("gone")
        let move = LibraryMigration.Move(source: missing, destinationFolder: root.appendingPathComponent("dest"))
        let result = LibraryMigration.execute([move])
        #expect(result.failed == [move])
        #expect(result.moved.isEmpty)
    }
}
```

- [ ] **Step 2: Implement LibraryMigration**

`Roger/Services/LibraryMigration.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryMigration")

/// Moves meeting sessions from the pre-library folder
/// (`~/Documents/Roger Recordings/<session>`) into
/// `<library>/Meetings/YYYY/MM/<session>`.
enum LibraryMigration {
    struct Move: Equatable {
        let source: URL
        let destinationFolder: URL
    }

    /// Start date from a session folder name (`yyyy-MM-dd HH-mm`, maybe with
    /// a ` 1` style suffix).
    static func sessionDate(for folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.count >= 16 else { return nil }
        return MeetingSession.folderNameFormatter.date(from: String(name.prefix(16)))
    }

    static func plan(sessionFolders: [URL], layout: LibraryLayout) -> [Move] {
        sessionFolders.map { folder in
            let date = sessionDate(for: folder)
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? Date()
            return Move(source: folder, destinationFolder: layout.monthFolder(.meetings, for: date))
        }
    }

    /// Moves each session. A name that is taken gets ` 1`, ` 2` … Returns
    /// the new folder URLs and the moves that failed (left in place).
    static func execute(_ moves: [Move]) -> (moved: [URL], failed: [Move]) {
        let fm = FileManager.default
        var moved: [URL] = []
        var failed: [Move] = []
        for move in moves {
            do {
                try fm.createDirectory(at: move.destinationFolder, withIntermediateDirectories: true)
                let base = move.source.lastPathComponent
                var target = move.destinationFolder.appendingPathComponent(base, isDirectory: true)
                var suffix = 1
                while fm.fileExists(atPath: target.path) {
                    target = move.destinationFolder.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
                    suffix += 1
                }
                try fm.moveItem(at: move.source, to: target)
                moved.append(target)
            } catch {
                logger.error("Could not move \(move.source.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(move)
            }
        }
        return (moved, failed)
    }
}
```

- [ ] **Step 3: Generate, run tests**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryMigrationTests 2>&1 | tail -20
```

Expected: 5 tests pass.

- [ ] **Step 4: Run the migration at launch**

Add to `AppCoordinator` (e.g. after `observeRecorderState`), with `import AppKit` already present:

```swift
    // MARK: - Library Migration

    /// One-time move of pre-library meetings into `<library>/Meetings/`.
    /// Asks first. Folders that stay in place become extra scan folders, so
    /// their meetings are still found.
    func runLibraryMigrationIfNeeded() {
        guard !appState.libraryMigrationDone, !meetingRecorder.isActive else { return }
        defer {
            appState.libraryMigrationDone = true
            pendingMeetingSessions = meetingRecorder.unfinalisedSessions()
        }

        var extras = appState.extraScanFolders
        func addExtra(_ url: URL) {
            if !extras.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                extras.append(url)
            }
        }
        if let transcripts = appState.legacyFileTranscriptFolder {
            addExtra(transcripts)
        }

        let layout = appState.libraryLayout
        let oldMeetings = appState.legacyMeetingRecordingsFolder ?? LibraryLayout.legacyRecordingsFolder
        let sessions = MeetingSessionScanner.sessionFolders(in: oldMeetings, maxDepth: 1)
        if !sessions.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Move your meetings to the Roger library?"
            alert.informativeText = "Roger now keeps log entries, meetings and transcripts in one folder: \(layout.root.path). Move \(sessions.count) meetings from \(oldMeetings.path) there? If you keep them in place, Roger still finds them."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Keep in Place")
            if alert.runModal() == .alertFirstButtonReturn {
                let result = LibraryMigration.execute(LibraryMigration.plan(sessionFolders: sessions, layout: layout))
                logger.notice("Library migration moved \(result.moved.count) meetings, \(result.failed.count) failed")
                if !result.failed.isEmpty {
                    addExtra(oldMeetings)
                }
            } else {
                addExtra(oldMeetings)
            }
        }
        appState.extraScanFolders = extras
    }
```

Check that `MeetingRecordingService` exposes `isActive` (it is used in `start()`); if it is private, use `if case .idle = meetingRecorder.state` instead.

In `RogerApp.swift` `applicationDidFinishLaunching`, directly after `let coordinator = sharedCoordinator` (and after the XCTest guard), add:

```swift
        // Move pre-library meetings before anything lists them.
        coordinator.runLibraryMigrationIfNeeded()
```

- [ ] **Step 5: Build and run all tests**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "error|BUILD" | tail -10
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`, `TEST SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger && git add Roger/Services/LibraryMigration.swift Roger/App/AppCoordinator.swift Roger/App/RogerApp.swift Roger/RogerTests/LibraryMigrationTests.swift Roger/Roger.xcodeproj
git commit -m "feat: offer to move old meetings into the library"
```

---

### Task 9: Preset editor and docs

**Files:**
- Modify: `Roger/UI/PresetsSettingsView.swift` (Output section ~line 148, list row ~line 40)
- Modify: `AGENTS.md` (gitignored local file: edit it, never `git add` it)

**Interfaces:**
- Consumes: `PresetOutput`, `DictationPreset.output`, `DictationPreset.keepAudio` (Task 3).

- [ ] **Step 1: Output section in the preset editor**

Replace the `Section { Picker("Append at end" ... } header: { Text("Output") } footer: { ... }` block with:

```swift
            Section {
                Picker("Output", selection: preset.output) {
                    ForEach(PresetOutput.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                if preset.wrappedValue.output == .logEntry {
                    Toggle("Keep audio", isOn: preset.keepAudio)
                } else {
                    Picker("Append at end", selection: preset.trailingCharacter) {
                        ForEach(TrailingCharacter.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Toggle("Press Return after insertion", isOn: preset.sendReturnAfterInsert)
                }
            } header: {
                Text("Output")
            } footer: {
                Text(preset.wrappedValue.output == .logEntry
                     ? "Saves the text as a Markdown file in the Logs folder of your Roger library. Nothing is typed. Keep audio also saves the recording as an .m4a file next to it."
                     : "Use Return to submit the text automatically. Handy for sending a prompt to a chat box or chat app.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
```

- [ ] **Step 2: Mark log presets in the list**

In the preset list row (near the `if preset.excludedFromRotation {` icon around line 40), add before it:

```swift
                    if preset.output == .logEntry {
                        Image(systemName: "book.closed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Saves to the log")
                    }
```

Match the existing icon styling there if it differs.

- [ ] **Step 3: Update AGENTS.md**

- In "Dictation Pipeline", add a line: "For presets with `output == .logEntry`, `LogEntryWriter` saves the text to `<library>/Logs/YYYY/MM/` instead of `TextInsertionService`."
- In "Key Services", add:
  - "**LibraryLayout** - Resolves the library root (default `~/Documents/Roger/`) and its `Logs/`, `Meetings/`, `Transcripts/` folders, each split by `YYYY/MM/`."
  - "**LogEntryWriter** - Writes log entries as OKF Markdown (`tags: [log]`), optional `.m4a` via `LogAudioEncoder`. File names never change after writing."
  - "**MeetingSessionScanner / LibraryMigration** - Find session folders in the nested layout and legacy folders; one-time move of `~/Documents/Roger Recordings/`."
- In "Dictation Presets": mention the Log preset (UUID `...0008`), `output` and `keepAudio`.
- Add a "Tests" line under Build & Run: `cd Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS'`, and that tests must not construct `AppState` (live UserDefaults in the host app).
- Use hyphens, not em-dashes, in new text.
- `AGENTS.md` is in `.gitignore`. Edit it in place and do not commit it.

- [ ] **Step 4: Build, test, commit**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
cd /Users/jordi/git/roger && git add Roger/UI/PresetsSettingsView.swift
git commit -m "feat: choose a preset's output in the preset editor"
```

---

## Manual verification (after all tasks)

1. Fresh state: with `~/Documents/Roger Recordings/` holding sessions, launch Debug Roger. The move dialog appears. Try "Keep in Place" once (reset with `defaults delete com.jordiboehme.roger libraryMigrationDone`), then "Move".
2. Settings → Presets: Log is there with the book icon. Bind it to Caps+Option. Record. The indicator is green with "Logging", then "Saving", then "Logged". The file is in `~/Documents/Roger/Logs/YYYY/MM/`. The popover shows "Saved to log - Show in Finder".
3. Duplicate Log, turn on Keep audio, record. The `.m4a` is next to the `.md` and plays.
4. Normal dictation still types at the cursor, with pink and cyan accents.
5. Record a short meeting. It lands in `Meetings/YYYY/MM/`. Turn off Keep audio after transcription, record again: no `mic.m4a`/`system.m4a`, no `sources` in `transcript.md`.
6. Drop a media file on the menu bar icon. The transcript lands in `Transcripts/YYYY/MM/`. Switch to "Next to the source file", drop again, and check `~/Library/Application Support/Roger/external-transcripts.json` lists it.
