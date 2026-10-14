# Text Input and Fixes (Roger 0.26.0, part A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every text file Roger reads goes through one decoder (`TextFile`: BOM, UTF-8, Windows-1252, LF line endings), the open issues #10 to #15 are closed and the findings set aside in 0.25.0 are fixed.

**Architecture:** A new Foundation-only `TextFile` in RogerKit replaces every `String(contentsOf:encoding: .utf8)` and `String(data:encoding: .utf8)` that feeds a parser, so no parser handles `\r` on its own. The library window fixes stay in the existing types (`InMemoryLibraryIndex`, `LibraryModel`, `LibraryActions`, the views) plus two small testable helpers (`LibraryRenameState`, `RelaunchGate`). The decisions that today live inside `AppCoordinator` and `MeetingRecordingService` move into three plain types (`LogEntrySaver`, `LibraryMigrationRun`, `MeetingFinalisationSteps`) that tests drive with temp folders. `get_changes` names its library and `ack` can check it.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AppKit, Foundation, Swift Testing, XcodeGen 2.46.0, Xcode 27, macOS 15+ on Apple Silicon. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-14-text-input-and-fixes-design.md` (binding). Issues: #10, #11, #12, #13, #14, #15 (`gh issue view <n> --repo jordiboehme/roger`).

## Global Constraints

From the spec (verbatim values):

- "Normalize on read only. Roger never rewrites a file just to convert it. When Roger writes a file anyway (edit, rename, retry), it writes UTF-8 with LF."
- Encoding order: "BOM first (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE), then UTF-8, then Windows-1252."
- Line endings: "`\r\n` and a lone `\r` become `\n`."
- "Keep `JSONDecoder` / `JSONSerialization` on raw `Data` (they accept `\r` as whitespace)."
- "SKILL.md compare: Stays a byte compare (SHA-256)."
- `TextFile` API: `public enum TextFile { static func read(_ url: URL) throws -> String; static func decode(_ data: Data) -> String; static func normalizeLineEndings(_ text: String) -> String }` in `Roger/RogerKit/TextFile.swift`, Foundation only.
- "`decode` never fails. Windows-1252 maps every byte (the five undefined bytes 0x81, 0x8D, 0x8F, 0x90, 0x9D map to the same code points as in Latin-1)." "A BOM is removed from the result." "`read` throws only the file system error (missing file, no permission), never an encoding error."
- "Quoted frontmatter values keep their `\r` escape (that is a value, not a line ending)."
- "Writers already write UTF-8 with LF and stay as they are. The editor's body is normalized before it is saved."
- #15: "`get_changes` puts `library: <canonical root path>` in its TOON head." "`ack` takes an optional `library` argument. If it is given and differs from the current canonical root, `ack` refuses: "The library changed since get_changes. Call get_changes again." Nothing is written." "Without `library`, `ack` behaves as before."
- "File names never change on write." "Library files are the user's data. Nothing in this part deletes or overwrites an item file beyond the existing rules." "Change events are recorded only after a write succeeded."
- Left out on purpose: "the symlink check race in the skill installer, pid reuse after a forced kill, a call that arrives right before `roger-mcp` exits, `since` with a clock that went backwards, Cursor seeing the skill twice, Install next to an unreadable config."
- "The release notes for 0.26.0 are written once part B is done."

Project rules:

- Work on branch `feat/text-input-and-fixes` in `/Users/jordi/git/roger` (already checked out). Do not switch branches.
- macOS 15.0 deployment target, Swift 6 strict concurrency with no new warnings, `@MainActor` for `@Observable` types SwiftUI observes. arm64 only (do not add x86_64 anywhere).
- Logging via `os.Logger` with subsystem `com.jordiboehme.roger`. `roger-mcp` never calls `print` while serving.
- Commits: plain conventional-commit messages. NEVER add `Co-Authored-By`, "Generated with Claude Code" or any AI attribution.
- User-facing strings (UI text, alerts, error messages, tool descriptions, server instructions, SKILL.md, script messages): no em-dash "—" or en-dash "–" (use "-"), no Oxford comma ("A, B and C"), short plain sentences.
- Debug build: `cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | tail -20`. Never pass `CONFIGURATION_BUILD_DIR` for Debug.
- App tests (hosted in Roger.app, the scheme also runs RogerKitTests): `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -40`. Add `-only-testing:RogerTests/<SuiteName>` for one suite.
- RogerKit tests (no host app): `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' 2>&1 | tail -40`. Add `-only-testing:RogerKitTests/<SuiteName>` for one suite.
- New files need the project regenerated: `cd /Users/jordi/git/roger/Roger && xcodegen generate`. After every `xcodegen generate`: run `git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements` (xcodegen empties it), check `git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements` prints nothing, and commit the regenerated `Roger/Roger.xcodeproj` with the task. `Package.resolved` is tracked; commit it if it changes.
- Tests must NEVER construct `AppState` or `AppCoordinator`, never read or write `UserDefaults.standard`, never touch `~/Documents`, `~/.claude`, `~/.agents` or any real harness folder, never call `ExternalTranscriptRegistry.standard`, never move anything to the real Trash. Use temp folders (`TempFolder.make()` in RogerTests, `TempDir.make()` in RogerKitTests) and injected roots and closures.
- `AGENTS.md` is in `.gitignore`. Edit it in place (Final checks), never `git add` it.
- Do not bump `MARKETING_VERSION` and do not write release notes. CI, the release rehearsal and the tag are not part of this plan.

## Review Focus

1. A note written on Windows (CRLF, Windows-1252 umlauts) is renamed and then edited in the library window: the frontmatter title and the H1 change, nothing else is lost, and the file is UTF-8 with LF afterwards. (Task 3: `renameOfEveryVariantWritesUTF8WithLF`, `saveOfEveryVariantKeepsTheFrontmatter`.)
2. A library entry whose `.md` is a symlink is edited while another app changes the link target: Roger must still see "changed on disk", and after a save the link is still a link and the target holds the text. (Task 12: `saveWritesThroughASymlink`, `targetChangedBehindALinkIsDetected`.)
3. The library folder is switched in Roger between `get_changes` and `ack`: an `ack` that passes the old `library` must refuse and write nothing, also when the two spellings differ only by `/var` vs `/private/var`. (Task 14: `ackRefusesAnotherLibrary`, `ackAcceptsAnotherSpellingOfTheSameLibrary`.)
4. The library root lives on a drive that is not connected: Roger must not create folders for it (neither the change log nor the index), the window says "Library folder not found" and the list comes back when the folder appears and Roger becomes active. (Task 5: `changeLogNeverCreatesAMissingRoot`, `recheckFindsARootThatAppeared`.)
5. Rename: Return followed by a click elsewhere commits once; Esc followed by the focus loss commits nothing. (Task 8: `commitHappensOnce`, `cancelThenFocusLossCommitsNothing`.)

## Rulings

Where the spec is silent or needed a decision, these rulings apply. Reviewers: treat them as part of the spec.

1. **TextFile decode.** Order: UTF-32 BE BOM, UTF-32 LE BOM (checked before UTF-16 LE, both start with `FF FE`), UTF-8 BOM, UTF-16 BE BOM, UTF-16 LE BOM, valid UTF-8, Windows-1252. After a BOM decoding never fails: a lone surrogate, an odd last byte or a short UTF-32 tail becomes U+FFFD. Windows-1252 uses Roger's own 32-entry table for 0x80 to 0x9F, because Foundation's `.windowsCP1252` returns nil for the whole text when one of the five undefined bytes appears (checked 2026-10-14 with Xcode 27). Line endings are normalized on Unicode scalars, because `"\r\n"` is one Swift `Character` (`"a\r\nb".split(separator: "\n").count == 1`, which is the cause of #11).
2. **Shared samples.** The five sample files live in `Roger/TestSupport/TextSamples.swift`, compiled into both RogerKitTests and RogerTests (one more `sources` path in `project.yml` each).
3. **Where `library:` goes.** It is the last line of the `get_changes` TOON head (`from`, `upTo`, `more`, `count`, `library`), so answers still start with `from:`. Its value is `LibraryPath.canonical(root)`. `ack` compares `LibraryPath.canonical` of both sides. The refusal is `isError`. Tests that compare the whole head change: `RogerToolsTests.consumerLoopEndsEmpty` and `RogerMCPEndToEndTests` (Task 14). `ChangeQueryTests` keep calling `render()` without a library and stay as they are.
4. **Missing library root.** The change log never creates the library root: `ChangeLog` throws when the root is not an existing folder and only creates `.roger/` inside it. At launch and on "Use Default" Roger creates the root only when it is the default `~/Documents/Roger/` (first launch). Writers (log entries, meetings, transcripts) still create the folders they write into, as before. A missing custom root stays missing until the user fixes it.
5. **Index paths.** A changed path is ignored when any path component below its kind folder or extra folder starts with `.` (the folders above may be hidden). A meeting change maps to the session folder found first among the meeting folders the index already knows, then on disk, at most 3 levels below `Meetings/` and 1 level below an extra folder (the depths of the full scan). Nothing found: the changed folder is read again as a tree.
6. **Unfinished meetings.** Audio files are `mic.m4a`, `system.m4a` (when present) and the CAF chunks, sorted by name. The screenshot count comes from `markers.json`, else it counts the image files in the session folder (the issue lists both).
7. **Extra files refresh.** The index yields a change for every change inside a meeting folder, also when the meeting item stayed the same. The model counts its applied reloads (`reloadCount`), and the Extra files section lists its folder again when that count changes.
8. **Subfolders in a meeting folder.** They are listed in Extra files, one row per subfolder, with Reveal in Finder and no Trash button. Directories are never moved from the section, also when the name looks like an extra file. Moving the whole meeting to the Trash still refuses a folder with subfolders.
9. **Pinned entry.** After a save or a rename the entry stays in the list and selected, even when it no longer matches the search, the date filter or the sidebar kind, until the selection changes. The pin is dropped when the entry is gone from the index.
10. **Unfinished toolbar.** While Unfinished is selected the date and sort menus are disabled. The search field cannot be disabled through SwiftUI; it stays visible, ignores input and shows the prompt "Search is off for Unfinished". The search text of the other lists is kept.
11. **Rename.** Return commits. Focus leaving the field commits. A click in the detail pane outside the field ends editing (focus moves away). Esc cancels. `LibraryRenameState` makes sure one rename commits at most once.
12. **List row height.** No fix is known that is reliable without rebuilding the list. Best candidate: every row has the same fixed height (all lines are `lineLimit(1)` already, a log row reserves the empty preview line), and the list's default minimum row height is set to that height, so the table's first-row height is right for every row. Task 10 has a manual check with the snapshot runner and a fallback.
13. **Relaunch.** "Relaunch Roger" goes through the normal quit path: the unsaved-edit question first, then a helper that waits until this process is gone (`kill -0 <pid>` loop) and opens the app again. The helper starts only after the question was answered with Save or Don't Save.
14. **Leftover in a retry error.** `MeetingRecordingError.trackAudioFailed` carries the set-aside file names and adds "Some audio is also saved as <names> in the meeting folder."
15. **Finalise.** `pendingMeetingSessions` keeps only folders that `LibraryActions.isRogerSessionFolder` accepts, so both the popover banner and the Unfinished list follow it.
16. **Symlinked Markdown.** Load, rename and save resolve the file once (`LibraryPath.canonicalURL`) and use the target for the modification date, the scratch folder and `replaceItemAt`. The link stays a link.
17. **Testability types.** `LogEntrySaver`, `LibraryMigrationRun` and `MeetingFinalisationSteps` take plain values (layout, folders, flags, closures), never `AppState`. `AppCoordinator` and `MeetingRecordingService` keep the UI side (panels, alerts, state).
18. **Test host.** `RogerApp.body` builds `Settings { EmptyView() }` under XCTest, so the global `sharedCoordinator` is never created there. A DEBUG counter `AppCoordinator.instancesCreated` pins it in a test.
19. **`recordWritten(root:)`.** The event goes into the change log of the root the writer used. The catch-up of a root runs only when that root is the current one.
20. **File found twice.** First found wins in the full scan of the index (the same order as `LibraryScanner`: Logs, Transcripts, Meetings, extra folders, external list). A change of an extra folder itself or of the external-transcripts list reads everything again (both are rare), so the rule also holds after them.
21. **fsync.** The change log calls `fsync` after each append. A bookmark is written to its temp file through a descriptor that is `fsync`ed before the `rename`. The folder itself is not `fsync`ed.
22. **TOML.** The Codex reader accepts spaces and a `# comment` after the header and after the value, and `[mcp_servers."roger"]` or `[mcp_servers.'roger']`. Values are single-line basic (`"..."`) or literal (`'...'`) strings.
23. **ingest-roger.sh.** `max-runs` must match `^[1-9][0-9]*$`, else exit 2 with the usage line. `RESULT:` is read only from the last non-empty line of a run's output.
24. **Unexpected tool error.** `"<tool> failed in the library at <root path>: <error>"`. `status` with a change log it cannot read answers `state: not readable` and `message: Roger cannot read the change log at <path>: <error>`.
25. **Extension icon.** `DesktopExtensionBuilder.iconPNG(for:size:)` defaults to 512.
26. **Patterns.** "Patterns compiled once" is met by replacing RogerKit's three regex checks (`TOON.needsQuotes`, `TOON.key`, `SinceParser`) with plain code. `PostProcessor` builds its regexes per call too, but it is not part of the 0.25.0 findings and stays.
27. **No-op ack.** An `ack` whose `upTo` is not newer than the bookmark returns before taking the lock, so it writes nothing (not even `.roger/consumers/` or its lock file). Found by the spec's "the six tools write nothing in an empty library" test.
28. **Catch-up without a root.** When the root is missing, `LibraryChangeRecorder`'s catch-up fails with a logged warning (as any failed write does) and runs again on the next `reconcile()` (launch, folder change).

## File Map

| File | Task | Responsibility |
|---|---|---|
| `Roger/RogerKit/TextFile.swift` | 1 | Decode bytes, normalize line endings |
| `Roger/TestSupport/TextSamples.swift` | 1 | The five sample files for both test targets |
| `Roger/project.yml` | 1 | `TestSupport` in both test targets |
| `Roger/RogerKit/LibraryItemReader.swift` | 2, 6 | Read through `TextFile`; unfinished audio and screenshots |
| `Roger/RogerKit/MeetingSessionScanner.swift`, `ItemResolver.swift` | 2 | Read through `TextFile` |
| `Roger/Services/Library/LibraryDocument.swift` | 3, 12 | Load, rename, save through `TextFile`; symlinks |
| `Roger/Services/MeetingRecording/MeetingSegmentWriter.swift` | 3 | Retry compare and draft check through `TextFile` |
| `Roger/Services/Library/LibraryActions.swift` | 3, 9, 11 | `hasMeetingTranscript`; subfolders; busy message; `finalisable` |
| `Roger/Services/Agents/HarnessRegistration.swift` | 3, 23 | TOML through `TextFile`; comments and quoted headers |
| `Roger/Services/Library/LibraryIndex.swift` | 4, 5, 8, 9, 25 | Hidden paths, sessions at any depth, missing root, refresh, change counter, first find wins |
| `Roger/RogerKit/ChangeLog.swift` | 5, 16 | Never create the root; `fsync` |
| `Roger/RogerKit/LibraryLayout.swift` | 5 | `createRootIfDefault` |
| `Roger/UI/Library/LibraryModel.swift` | 5, 7, 8, 9 | Missing root, `usesFilters`, pin and `didWrite`, `reloadCount` |
| `Roger/UI/Library/LibraryEmptyState.swift`, `LibraryListView.swift` | 5, 10 | "Library folder not found"; no list rebuild |
| `Roger/App/LibraryWindowController.swift` | 5 | Recheck the root on activation |
| `Roger/Services/Library/LibraryIndexStore.swift` | 6 | Keep the stop task |
| `Roger/Services/Library/LibraryQuery.swift`, `Roger/UI/Library/LibraryView.swift` | 7 | Title sort by row text; no filters for Unfinished |
| `Roger/UI/Library/LibraryRenameState.swift`, `LibraryDetailView.swift` | 8, 9, 24 | One commit per rename; immediate update; section refresh; roots |
| `Roger/Services/MeetingRecording/MeetingExtraFiles.swift`, `Roger/UI/Library/LibraryExtraFilesSection.swift` | 9 | Subfolder rows, refresh, refusal message |
| `Roger/App/LibrarySnapshotRunner.swift` | 10 | Refill snapshot for the manual check |
| `Roger/Models/MeetingRecordingError.swift` | 11 | Name leftovers in a retry error |
| `Roger/App/AppRelauncher.swift`, `Roger/App/RogerApp.swift` | 5, 13, 21 | Default root at launch; relaunch after the question; test host |
| `Roger/RogerKit/ChangeQuery.swift`, `RogerTools.swift` | 14, 15 | `library` head and argument; error texts |
| `Roger/RogerMCP/ToolCatalog.swift`, `skills/ingest-roger/SKILL.md` | 14 | `ack` schema and docs |
| `Roger/RogerKit/FileLock.swift`, `ConsumerBookmarks.swift` | 16, 28 | `FileIO`, `fsync`; no-op ack |
| `Roger/RogerKit/RFC3339.swift`, `ChangeEvent.swift` | 17 | Shared formatters and decoder |
| `Roger/Services/LogEntrySaver.swift` | 18 | Log entry after dictation |
| `Roger/Services/LibraryMigrationRun.swift` | 19 | First-launch migration |
| `Roger/Services/MeetingRecording/MeetingFinalisationSteps.swift`, `MeetingRecordingService.swift` | 20, 24 | Finalisation file steps; session root |
| `Roger/App/AppCoordinator.swift` | 11, 18, 19, 21, 24 | Finalise filter, extracted types, counter, roots |
| `Roger/Services/Agents/AgentsStatus.swift`, `AgentsController.swift`, `Roger/UI/AgentsSettingsView.swift` | 22 | Off the main actor; consumers without a log |
| `Roger/Services/Library/LibraryChangeRecorder.swift` | 24 | `recordWritten(root:)` |
| `scripts/ingest-roger.sh`, `scripts/test-ingest-roger.sh`, `.github/workflows/release.yml` | 26 | Run count, last line; TeamIdentifier and timestamp |
| `Roger/RogerKit/TOON.swift`, `SinceParser.swift`, `SessionFolderName.swift`, `Roger/Services/Agents/DesktopExtensionBuilder.swift` | 27 | No regex, reused formatters, 512 px icon |
| `Roger/UI/RecordingsSettingsView.swift` | 5 | Default root on Reset |
| `AGENTS.md` (local only) | Final checks | TextFile, new types, recorder |
| Tests | all | Named per task |

Task order follows the spec's Delivery section: Tasks 1-3 (TextFile, #11), 4-6 (#13), 7-10 (#12), 11-13 (#14), 14-17 (#15 and findings 4, 1, 2), 18-21 (#10), 22-28 (findings 3, 5 to 11), then the Final checks (no commit of their own).

---

### Task 1: TextFile and the shared text samples

The one decoder every text read goes through (#11), with the five sample files both test targets use.

**Files:**
- Create: `Roger/RogerKit/TextFile.swift`
- Create: `Roger/TestSupport/TextSamples.swift`
- Modify: `Roger/project.yml` (targets `RogerKitTests` and `RogerTests`, `sources`)
- Test: `Roger/RogerKitTests/TextFileTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `public enum TextFile { public static func read(_ url: URL) throws -> String; public static func decode(_ data: Data) -> String; public static func normalizeLineEndings(_ text: String) -> String }` (module RogerKit, re-exported to the app).
  - Test helper (both test targets): `enum TextSample: String, CaseIterable, Sendable { case crlf, crOnly, utf8BOM, utf16LEBOM, windows1252; static let text: String; static let title: String; static let firstLine: String; static let startedAt: Date; var data: Data; @discardableResult func write(to url: URL) throws -> URL }`.

- [ ] **Step 1: Add the test support folder to both test targets**

In `Roger/project.yml`, change the `sources` of `RogerKitTests` and `RogerTests`:

```yaml
  RogerKitTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: RogerKitTests
      - path: TestSupport
```

```yaml
  RogerTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: RogerTests
      - path: TestSupport
```

- [ ] **Step 2: Write the samples**

`Roger/TestSupport/TextSamples.swift`:

```swift
import Foundation

/// One Roger-style log entry in the five shapes other editors write:
/// CRLF, CR only, a UTF-8 BOM, UTF-16 LE with a BOM and Windows-1252.
/// Shared by RogerKitTests and RogerTests (`Roger/TestSupport`).
enum TextSample: String, CaseIterable, Sendable {
    case crlf
    case crOnly
    case utf8BOM
    case utf16LEBOM
    case windows1252


    /// What every variant decodes to: UTF-8 with LF.
    static let text = """
    ---
    type: source
    title: "Grüße aus Köln"
    tags: [log, reise]
    started_at: 2026-10-13T14:32:05+02:00
    duration_seconds: 33
    ---
    # Grüße aus Köln

    Ärger über die Lieferung, Kosten 5 €.
    Zweite Zeile.

    """

    static let title = "Grüße aus Köln"
    static let firstLine = "Ärger über die Lieferung, Kosten 5 €."
    static let startedAt = Date(timeIntervalSince1970: 1_791_894_725)

    /// The file's bytes.
    var data: Data {
        let text = Self.text
        switch self {
        case .crlf:
            return Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        case .crOnly:
            return Data(text.replacingOccurrences(of: "\n", with: "\r").utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16LEBOM:
            return Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        case .windows1252:
            return text.replacingOccurrences(of: "\n", with: "\r\n").data(using: .windowsCP1252)!
        }
    }

    /// Writes the bytes to `url` (creating the folder) and returns `url`.
    @discardableResult
    func write(to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
```

- [ ] **Step 3: Write the failing tests**

`Roger/RogerKitTests/TextFileTests.swift`:

```swift
import Foundation
import Testing
@testable import RogerKit

struct TextFileTests {
    @Test(arguments: TextSample.allCases)
    func everyVariantDecodesToUTF8WithLF(_ sample: TextSample) {
        #expect(TextFile.decode(sample.data) == TextSample.text)
    }

    @Test func lineEndings() {
        #expect(TextFile.normalizeLineEndings("a\r\nb\rc\nd") == "a\nb\nc\nd")
        #expect(TextFile.normalizeLineEndings("a\r\r\nb") == "a\n\nb")
        #expect(TextFile.normalizeLineEndings("a\n\rb") == "a\n\nb")
        #expect(TextFile.normalizeLineEndings("end\r") == "end\n")
        #expect(TextFile.normalizeLineEndings("plain") == "plain")
    }

    @Test func bomIsNotPartOfTheText() {
        #expect(TextFile.decode(Data([0xEF, 0xBB, 0xBF, 0x41])) == "A")
        #expect(TextFile.decode(Data([0xFE, 0xFF, 0x00, 0x41])) == "A")
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x41, 0x00])) == "A")
        #expect(TextFile.decode(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41])) == "A")
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])) == "A")
    }

    @Test func brokenBOMFilesStillDecode() {
        // Odd byte count after a UTF-16 BOM, a lone surrogate, a short UTF-32 tail.
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x41, 0x00, 0x42])) == "A\u{FFFD}")
        #expect(TextFile.decode(Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00])) == "\u{FFFD}A")
        #expect(TextFile.decode(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00])) == "\u{FFFD}")
        #expect(TextFile.decode(Data([0xEF, 0xBB, 0xBF, 0xFF])) == "\u{FFFD}")
    }

    @Test func windows1252MapsEveryByte() {
        let undefined: [UInt8] = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
        // Foundation refuses these; Roger maps them like Latin-1.
        #expect(String(data: Data(undefined), encoding: .windowsCP1252) == nil)
        #expect(TextFile.decode(Data(undefined)).unicodeScalars.map(\.value) == [0x81, 0x8D, 0x8F, 0x90, 0x9D])
        #expect(TextFile.decode(Data([0x80, 0x93, 0x94, 0xE4, 0xDF])) == "€“”äß")
        let all = TextFile.decode(Data((0...255).map { UInt8($0) } + [0xFF]))
        #expect(all.unicodeScalars.count == 257)
    }

    @Test func validUTF8WinsOverWindows1252() {
        #expect(TextFile.decode(Data("Grüße".utf8)) == "Grüße")
        #expect(TextFile.decode(Data([0x47, 0x72, 0xFC, 0xDF, 0x65])) == "Grüße")
    }

    @Test func readThrowsOnlyFileErrors() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        #expect(throws: (any Error).self) { try TextFile.read(folder.appendingPathComponent("missing.md")) }
        let url = try TextSample.windows1252.write(to: folder.appendingPathComponent("w.md"))
        #expect(try TextFile.read(url) == TextSample.text)
    }
}
```

- [ ] **Step 4: Regenerate the project and run the tests to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/TextFileTests 2>&1 | tail -20`
Expected: build FAILS with "cannot find 'TextFile' in scope".

- [ ] **Step 5: Write TextFile**

`Roger/RogerKit/TextFile.swift`:

```swift
import Foundation

/// The one way Roger reads text files: UTF-8 text with LF line endings,
/// whatever encoding or line endings the file has. Roger never rewrites a
/// file just to convert it; files it writes anyway are UTF-8 with LF.
public enum TextFile {
    /// Reads a text file as UTF-8 with LF line endings. Throws only the
    /// file system error (missing file, no permission), never an encoding
    /// error.
    public static func read(_ url: URL) throws -> String {
        decode(try Data(contentsOf: url))
    }

    /// Decodes bytes: a BOM (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE) first, then
    /// UTF-8, then Windows-1252. Never fails. The BOM is not part of the
    /// result. Line endings become LF.
    public static func decode(_ data: Data) -> String {
        normalizeLineEndings(decodeBytes([UInt8](data)))
    }

    /// `\r\n` and a lone `\r` become `\n`. Works on Unicode scalars: in a
    /// Swift `String`, `"\r\n"` is one `Character`.
    public static func normalizeLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        var out = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                afterCR = true
                continue
            }
            if scalar == "\n", afterCR {
                afterCR = false
                continue
            }
            afterCR = false
            out.append(scalar)
        }
        return String(out)
    }

    // MARK: - Decoding

    private static func decodeBytes(_ bytes: [UInt8]) -> String {
        // UTF-32 LE before UTF-16 LE: both start with FF FE.
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return utf32(bytes.dropFirst(4), bigEndian: true) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return utf32(bytes.dropFirst(4), bigEndian: false) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFE, 0xFF]) { return utf16(bytes.dropFirst(2), bigEndian: true) }
        if bytes.starts(with: [0xFF, 0xFE]) { return utf16(bytes.dropFirst(2), bigEndian: false) }
        if let text = String(validating: bytes, as: UTF8.self) { return text }
        return windows1252(bytes)
    }

    /// Pairs of bytes; a lone surrogate or a last odd byte becomes U+FFFD.
    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2 + 1)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            units.append(bigEndian ? (a << 8 | b) : (b << 8 | a))
            index += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        if index < bytes.endIndex { text.unicodeScalars.append("\u{FFFD}") }
        return text
    }

    /// Groups of four bytes; an invalid scalar or a short tail becomes U+FFFD.
    private static func utf32(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var index = bytes.startIndex
        while index + 3 < bytes.endIndex {
            let quad = (0..<4).map { UInt32(bytes[index + $0]) }
            let value = bigEndian
                ? (quad[0] << 24 | quad[1] << 16 | quad[2] << 8 | quad[3])
                : (quad[3] << 24 | quad[2] << 16 | quad[1] << 8 | quad[0])
            scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            index += 4
        }
        if index < bytes.endIndex { scalars.append("\u{FFFD}") }
        return String(scalars)
    }

    /// 0x80 to 0x9F per Windows-1252. The five bytes it leaves undefined
    /// (0x81, 0x8D, 0x8F, 0x90, 0x9D) and every other byte map to the same
    /// code point as in Latin-1. Foundation's `.windowsCP1252` refuses the
    /// whole text when one of the five appears, so the table is Roger's own.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    private static func windows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            let value = (0x80...0x9F).contains(byte) ? cp1252High[Int(byte) - 0x80] : UInt32(byte)
            // Every table value is a valid scalar.
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/TextFileTests 2>&1 | tail -20`
Expected: `TextFileTests` passes (7 tests, the variant test with 5 cases).

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/RogerKit/TextFile.swift Roger/TestSupport/TextSamples.swift Roger/RogerKitTests/TextFileTests.swift Roger/project.yml Roger/Roger.xcodeproj
git commit -m "feat: read text files in any common encoding and line ending"
```

---

### Task 2: RogerKit readers use TextFile

`LibraryItemReader`, `MeetingSessionScanner.transcriptReportsFailedAudio` and `ItemResolver.markdown(of:)` (and through it `get_item`, `get_changes` and `search`) read through `TextFile`.

**Files:**
- Modify: `Roger/RogerKit/LibraryItemReader.swift:17`
- Modify: `Roger/RogerKit/MeetingSessionScanner.swift:40`
- Modify: `Roger/RogerKit/ItemResolver.swift:58-61`
- Test: `Roger/RogerKitTests/TextInputTests.swift`

**Interfaces:**
- Consumes: `TextFile.read(_:)`, `TextFile.decode(_:)`, `TextSample` (Task 1).
- Produces: no new names. `ItemResolver.markdown(of:)` keeps its signature and now returns nil only when the file cannot be read.

- [ ] **Step 1: Write the failing tests**

`Roger/RogerKitTests/TextInputTests.swift`:

```swift
import Foundation
import Testing
@testable import RogerKit

/// Files written by other editors: every RogerKit reader sees the same
/// UTF-8 text with LF.
struct TextInputTests {
    @Test(arguments: TextSample.allCases)
    func frontmatterIsFound(_ sample: TextSample) throws {
        let front = try #require(LibraryFrontmatterParser.parse(TextFile.decode(sample.data)))
        #expect(front.scalars["title"] == TextSample.title)
        #expect(front.scalars["started_at"] == "2026-10-13T14:32:05+02:00")
        #expect(front.tags == ["log", "reise"])
    }

    @Test(arguments: TextSample.allCases)
    func readerGivesTheRightItem(_ sample: TextSample) throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("entry.md"))
        let item = try #require(LibraryItemReader.item(markdownAt: url, fallbackKind: .transcript))
        #expect(item.kind == .log)
        #expect(item.title == TextSample.title)
        #expect(item.date == TextSample.startedAt)
        #expect(item.durationSeconds == 33)
        #expect(item.firstLine == TextSample.firstLine)
        #expect(item.searchText.contains("ärger über die lieferung"))
        #expect(!item.searchText.contains("\r"))
    }

    @Test(arguments: TextSample.allCases)
    func markdownForToolsIsUTF8WithLF(_ sample: TextSample) throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("entry.md"))
        let item = try #require(LibraryItemReader.item(markdownAt: url, fallbackKind: .log))
        #expect(ItemResolver.markdown(of: item) == TextSample.text)
        let hit = try #require(ItemSearch.search("lieferung", in: [item], kind: nil, limit: 5).first)
        #expect(hit.snippet.contains("Ärger über die Lieferung"))
    }

    @Test func failedAudioFlagIsFoundInACRLFTranscript() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let transcript = folder.appendingPathComponent("transcript.md")
        try Data("---\r\ntags: [meeting, transcript]\r\nmic_audio_failed: true\r\n---\r\n# Meeting\r\n".utf8).write(to: transcript)
        #expect(MeetingSessionScanner.transcriptReportsFailedAudio(transcript))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/TextInputTests 2>&1 | tail -30`
Expected: FAIL. `frontmatterIsFound` passes already (it decodes first), `readerGivesTheRightItem`, `markdownForToolsIsUTF8WithLF` and `failedAudioFlagIsFoundInACRLFTranscript` fail (no title, no frontmatter, `\r` in the text).

- [ ] **Step 3: Read through TextFile**

`Roger/RogerKit/LibraryItemReader.swift`, in `item(markdownAt:fallbackKind:folder:)` replace the first line of the body:

```swift
        let text = (try? TextFile.read(url)) ?? ""
```

`Roger/RogerKit/MeetingSessionScanner.swift`, in `transcriptReportsFailedAudio(_:)` replace the guard:

```swift
        guard let text = try? TextFile.read(transcript) else { return false }
```

`Roger/RogerKit/ItemResolver.swift`, replace `markdown(of:)` and its comment:

```swift
    /// The whole file as UTF-8 text with LF line endings (see `TextFile`);
    /// nil only when the file cannot be read.
    public static func markdown(of item: LibraryItem) -> String? {
        try? TextFile.read(item.url)
    }
```

- [ ] **Step 4: Run all RogerKit tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass (118 tests in 17 suites).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/RogerKit/LibraryItemReader.swift Roger/RogerKit/MeetingSessionScanner.swift Roger/RogerKit/ItemResolver.swift Roger/RogerKitTests/TextInputTests.swift
git commit -m "fix: read library files with Windows line endings and other encodings"
```

---

### Task 3: App readers use TextFile

`LibraryDocument.load`, `LibraryDocumentEditor.rename` and `saveBody`, `MeetingSegmentWriter` (existing segment, `sameContent`, `isDraft`), `LibraryActions.hasMeetingTranscript` and the Codex TOML reader read through `TextFile`. The `\r` kept on the H1 line goes away. The editor's body is normalized before it is saved. The mtime check stays.

**Files:**
- Modify: `Roger/Services/Library/LibraryDocument.swift`
- Modify: `Roger/Services/MeetingRecording/MeetingSegmentWriter.swift:53-61, 68-70, 117-118`
- Modify: `Roger/Services/Library/LibraryActions.swift:158-163`
- Modify: `Roger/Services/Agents/HarnessRegistration.swift:71`
- Test: `Roger/RogerTests/LibraryDocumentTests.swift` (replace `renameKeepsCarriageReturnOnHeading`, add variant tests)
- Test: `Roger/RogerTests/MeetingSegmentWriterTests.swift`, `Roger/RogerTests/LibraryActionsTests.swift`, `Roger/RogerTests/HarnessRegistrationTests.swift`

**Interfaces:**
- Consumes: `TextFile`, `TextSample` (Task 1).
- Produces: no new names. `LibraryDocument.load(_:)` no longer throws `fileReadInapplicableStringEncoding`. `LibraryDocument.frontmatter + body` is now the file's text after `TextFile` (UTF-8, LF), not its raw bytes.

- [ ] **Step 1: Write the failing tests**

In `Roger/RogerTests/LibraryDocumentTests.swift`, delete the test `renameKeepsCarriageReturnOnHeading` and add these tests to the struct (after `renameSkipsHeadingsInsideCodeFences`):

```swift
    /// A file from another editor: after a rename it is UTF-8 with LF, the
    /// title and the H1 changed, and every other line is still there.
    @Test(arguments: TextSample.allCases)
    func renameOfEveryVariantWritesUTF8WithLF(_ sample: TextSample) throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("note.md"))
        try LibraryDocumentEditor.rename(fileAt: url, to: "Neuer Titel")
        let expected = TextSample.text
            .replacingOccurrences(of: "title: \"\(TextSample.title)\"", with: "title: \"Neuer Titel\"")
            .replacingOccurrences(of: "# \(TextSample.title)", with: "# Neuer Titel")
        #expect(try Data(contentsOf: url) == Data(expected.utf8))
    }

    @Test(arguments: TextSample.allCases)
    func saveOfEveryVariantKeepsTheFrontmatter(_ sample: TextSample) throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try sample.write(to: folder.appendingPathComponent("note.md"))
        let document = try LibraryDocument.load(url)
        #expect(document.frontmatter + document.body == TextSample.text)
        #expect(document.frontmatter.contains("title: \"\(TextSample.title)\"\n"))
        #expect(try LibraryDocumentEditor.saveBody("# Neu\r\n\r\nGeändert\r\n", of: document) == .saved)
        #expect(try Data(contentsOf: url) == Data((document.frontmatter + "# Neu\n\nGeändert\n").utf8))
    }

    @Test func renameNeedsNoCarriageReturnHandling() {
        // Text reaching `renamed` is already normalized by TextFile.
        #expect(LibraryDocumentEditor.renamed("# Old\nBody\n", to: "New") == "# New\nBody\n")
    }
```

In `Roger/RogerTests/MeetingSegmentWriterTests.swift`, add at the end of the struct:

```swift
    /// A retry over a segment another editor saved with CRLF, unchanged
    /// otherwise: the file stays and no `.previous` copy is made.
    @Test func anUnchangedCRLFSegmentCountsAsUnchanged() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false, generatedAt: start)
        let crlf = try read(url).replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlf.utf8).write(to: url)
        _ = try write(folder, "Final words", provisional: false, generatedAt: start.addingTimeInterval(3 * 86_400))
        #expect(try names(folder) == [url.lastPathComponent])
        #expect(try Data(contentsOf: url) == Data(crlf.utf8))
    }

    @Test func aCRLFDraftIsStillADraft() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Live words", provisional: true)
        try Data(try read(url).replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: url)
        #expect(MeetingSegmentWriter.isDraft(url))
    }
```

In `Roger/RogerTests/LibraryActionsTests.swift`, add at the end of `LibraryActionsTests`:

```swift
    /// A legacy session in an extra folder whose transcript was saved with
    /// CRLF by another editor is still recognised by its meeting tag.
    @Test func crlfMeetingTranscriptIsRecognised() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let extra = root.appendingPathComponent("Notes", isDirectory: true)
        let folder = extra.appendingPathComponent("Planning", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\r\ntags: [meeting, transcript]\r\n---\r\n# Meeting\r\n".utf8)
            .write(to: folder.appendingPathComponent("transcript.md"))
        #expect(LibraryActions.isRogerSessionFolder(folder, layout: layout(root.appendingPathComponent("Roger")), extraFolders: [extra]))
    }
```

In `Roger/RogerTests/HarnessRegistrationTests.swift`, add after `readsCodexTOML`:

```swift
    @Test func readsACRLFCodexConfig() throws {
        let (home, _) = try home(with: [])
        defer { TempFolder.remove(home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"gpt-5\"\r\n\r\n[mcp_servers.roger]\r\ncommand = \"\(exe)\"\r\n".utf8).write(to: config)
        #expect(HarnessRegistration.connection(HarnessCatalog.spec(.codex), home: home, executable: exe) == .connected)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryDocumentTests -only-testing:RogerTests/MeetingSegmentWriterTests -only-testing:RogerTests/LibraryActionsTests -only-testing:RogerTests/HarnessRegistrationTests 2>&1 | tail -40`
Expected: FAIL: the variant rename and save tests (UTF-16 throws "not renamable", CRLF keeps `\r`), `anUnchangedCRLFSegmentCountsAsUnchanged` (a `.previous` copy appears), `aCRLFDraftIsStillADraft`, `crlfMeetingTranscriptIsRecognised` and `readsACRLFCodexConfig` (`\r` ends up in the command).

- [ ] **Step 3: LibraryDocument reads through TextFile**

In `Roger/Services/Library/LibraryDocument.swift`:

Replace `load(_:)`:

```swift
    static func load(_ url: URL) throws -> LibraryDocument {
        let text = try TextFile.read(url)
        let parts = LibraryFrontmatterParser.split(text)
        return LibraryDocument(
            url: url,
            frontmatter: parts.frontmatter.map(String.init) ?? "",
            body: String(parts.body),
            modificationDate: LibraryDocumentEditor.modificationDate(of: url)
        )
    }
```

and its type comment:

```swift
/// A library file as read from disk for the detail pane, through
/// `TextFile` (UTF-8, LF). `frontmatter + body` is that text.
```

Replace `rename(fileAt:to:)`:

```swift
    static func rename(fileAt url: URL, to title: String) throws {
        guard let renamed = renamed(try TextFile.read(url), to: title) else {
            throw RenameError.notRenamable
        }
        try write(renamed, to: url)
    }
```

In `saveBody(_:of:overwrite:)` replace the write line:

```swift
        try write(current.frontmatter + TextFile.normalizeLineEndings(body), to: url)
```

and add to its doc comment: `/// The body's line endings become LF.`

In `replacingHeading(in:with:)` replace the line that keeps `\r`:

```swift
        lines[index] = "# " + title
```

- [ ] **Step 4: MeetingSegmentWriter, LibraryActions and the TOML reader**

In `Roger/Services/MeetingRecording/MeetingSegmentWriter.swift`:

- in `write(...)`: `let existing = try? TextFile.read(url)`
- in `isDraft(_ url:)`: `isDraft(text: try? TextFile.read(url))`
- in `removeIfExists(chunkStart:folder:)`: `if isDraft(text: try? TextFile.read(url)) {`

`sameContent` stays as it is: both sides are LF now (the new text is built with LF, the old one comes from `TextFile`).

In `Roger/Services/Library/LibraryActions.swift`, in `hasMeetingTranscript(_:)`:

```swift
        guard let text = try? TextFile.read(transcript) else { return false }
```

In `Roger/Services/Agents/HarnessRegistration.swift`, in `connection(_:home:executable:)`:

```swift
            let lookup = spec.id == .codex ? tomlCommand(TextFile.decode(data)) : jsonCommand(data)
```

(`jsonCommand` keeps raw `Data`: `JSONSerialization` accepts `\r` as whitespace.)

- [ ] **Step 5: Run the suites and the whole app test scheme**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -30`
Expected: all RogerTests and RogerKitTests pass. `LibraryItemReaderTests.unreadableTextStillGivesAnItem` still passes: its bytes `FF FE 00 C3` now decode as UTF-16 LE (one Hangul syllable), and the title still falls back to the file name.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Library/LibraryDocument.swift Roger/Services/MeetingRecording/MeetingSegmentWriter.swift Roger/Services/Library/LibraryActions.swift Roger/Services/Agents/HarnessRegistration.swift Roger/RogerTests/LibraryDocumentTests.swift Roger/RogerTests/MeetingSegmentWriterTests.swift Roger/RogerTests/LibraryActionsTests.swift Roger/RogerTests/HarnessRegistrationTests.swift
git commit -m "fix: edit, rename and compare files with Windows line endings"
```

---

### Task 4: Index updates skip hidden paths and find sessions at any depth

Incremental updates follow the same rules as the full scan (#13): hidden files and folders below a kind folder or an extra folder are ignored, and a change inside a meeting folder that is not at `YYYY/MM/<session>` updates that meeting instead of dropping it.

**Files:**
- Modify: `Roger/Services/Library/LibraryIndex.swift` (`unit(forChangedPath:)`, two new private helpers)
- Test: `Roger/RogerTests/LibraryIndexTests.swift`

**Interfaces:**
- Consumes: `LibraryPath.components(of:below:)`, `MeetingSessionScanner.isSessionFolder(_:)` (existing).
- Produces: no new public names. `unit(forChangedPath:)` keeps its signature.

- [ ] **Step 1: Write the failing tests**

Add to `LibraryIndexTests` in `Roger/RogerTests/LibraryIndexTests.swift` (they use the file's existing helpers `writeLog`, `writeMeeting` and `makeIndex`):

```swift
    @Test func hiddenPartsBelowKindFoldersAreIgnored() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        let index = makeIndex(layout)
        let month = layout.monthFolder(.logs, for: date)
        #expect(await index.unit(forChangedPath: month.appendingPathComponent(".draft.md").path) == nil)
        #expect(await index.unit(forChangedPath: month.appendingPathComponent(".trash/old.md").path) == nil)
        #expect(await index.unit(forChangedPath: layout.kindFolder(.transcripts).appendingPathComponent(".cache/x.md").path) == nil)
        #expect(await index.unit(forChangedPath: layout.kindFolder(.meetings).appendingPathComponent("2026/.tmp/s/transcript.md").path) == nil)
    }

    /// A log inside a hidden folder (`.trash/`) is skipped by the full scan
    /// and by an update alike.
    @Test func aLogInAHiddenFolderIsNotAddedByAnUpdate() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let visible = try writeLog(layout, at: date, text: "Visible")
        let hidden = visible.deletingLastPathComponent().appendingPathComponent(".trash/old.md")
        try FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: visible, to: hidden)
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        await index.apply(changedPaths: [hidden.path])
        #expect(await index.items().map(\.id) == [LibraryPath.canonical(visible)])
    }

    /// A session directly in `Meetings/` (not at `YYYY/MM/`): editing its
    /// transcript updates the item instead of dropping it.
    @Test func aShallowSessionIsUpdatedInPlace() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.kindFolder(.meetings), name: "2026-09-21 09-00", text: "First")
        let index = makeIndex(layout)
        #expect(await index.items().first?.firstLine == "First")
        try writeMeeting(in: layout.kindFolder(.meetings), name: "2026-09-21 09-00", text: "Second")
        await index.apply(changedPaths: [folder.appendingPathComponent("transcript.md").path])
        let items = await index.items()
        #expect(items.count == 1)
        #expect(items.first?.firstLine == "Second")
    }

    @Test func aNewSessionTwoLevelsDownIsFound() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let index = makeIndex(layout)
        #expect(await index.items().isEmpty)
        let year = layout.kindFolder(.meetings).appendingPathComponent("2026", isDirectory: true)
        let folder = try writeMeeting(in: year, name: "2026-09-21 09-00", text: "Hello")
        await index.apply(changedPaths: [folder.appendingPathComponent("transcript.md").path])
        #expect(await index.items().map(\.folderURL.path) == [LibraryPath.canonical(folder)])
    }

    @Test func aTrashedShallowSessionIsDropped() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.kindFolder(.meetings), name: "s", text: "Bye")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        try FileManager.default.removeItem(at: folder)
        await index.apply(changedPaths: [folder.path])
        #expect(await index.items().isEmpty)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryIndexTests 2>&1 | tail -30`
Expected: FAIL in `hiddenPartsBelowKindFoldersAreIgnored`, `aLogInAHiddenFolderIsNotAddedByAnUpdate`, `aShallowSessionIsUpdatedInPlace` and `aNewSessionTwoLevelsDownIsFound`. (`aTrashedShallowSessionIsDropped` passes already and guards the new lookup.)

- [ ] **Step 3: Replace `unit(forChangedPath:)`**

In `Roger/Services/Library/LibraryIndex.swift`, replace the whole function `unit(forChangedPath:)` (with its doc comment, up to the line before `// MARK: - Watching`) with:

```swift
    /// Maps one changed path to what must be read again. Nil for paths
    /// outside the library and for hidden files and folders below a kind
    /// folder or an extra folder (the full scan skips them too).
    func unit(forChangedPath raw: String) -> LibraryScanUnit? {
        let path = LibraryPath.canonical(URL(fileURLWithPath: raw))
        if let list = externalListPath, path == list { return .externalList }
        if externalIDs.contains(path) { return .file(path, .transcript) }
        if LibraryPath.isPath(root, inside: path) { return .everything }
        for (folder, kind) in [(logs, LibraryItemKind.log), (transcripts, .transcript)]
        where LibraryPath.isPath(path, inside: folder) {
            guard !Self.hasHiddenPart(path, below: folder) else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "md" { return .file(path, kind) }
            // Audio next to a log entry: its .md says whether it has audio.
            if ext == "m4a" { return .file((path as NSString).deletingPathExtension + ".md", kind) }
            return ext.isEmpty ? .tree(path, kind) : nil
        }
        if LibraryPath.isPath(path, inside: meetings) {
            guard !Self.hasHiddenPart(path, below: meetings) else { return nil }
            // Sessions sit up to three levels down (`YYYY/MM/<session>` or
            // anywhere above), like the full scan finds them.
            return sessionFolder(containing: path, below: meetings, maxDepth: 3).map(LibraryScanUnit.session)
                ?? .tree(path, .meeting)
        }
        for extra in extras where LibraryPath.isPath(path, inside: extra) {
            guard !Self.hasHiddenPart(path, below: extra) else { return nil }
            let parts = LibraryPath.components(of: path, below: extra)
            guard let first = parts.first else { return .extraFolder(extra) }
            if parts.count == 1 {
                let ext = (first as NSString).pathExtension.lowercased()
                if ext == "md" { return .file(path, .transcript) }
                if !ext.isEmpty { return nil }
            }
            // Sessions sit directly in an extra folder.
            return .session(extra + "/" + first)
        }
        return nil
    }

    /// True when a part of `path` below `folder` starts with a dot.
    private static func hasHiddenPart(_ path: String, below folder: String) -> Bool {
        LibraryPath.components(of: path, below: folder).contains { $0.hasPrefix(".") }
    }

    /// The session folder that holds `path` (or is `path`): the shallowest
    /// folder at most `maxDepth` levels below `base` that the index knows as
    /// a meeting folder (also after it was deleted), else one that is a
    /// session folder on disk.
    private func sessionFolder(containing path: String, below base: String, maxDepth: Int) -> String? {
        var candidates: [String] = []
        var current = base
        for part in LibraryPath.components(of: path, below: base).prefix(maxDepth) {
            current = (current as NSString).appendingPathComponent(part)
            candidates.append(current)
        }
        guard !candidates.isEmpty else { return nil }
        let known = Set(itemsByID.values.filter { $0.kind == .meeting }.map(\.folderURL.path))
        if let hit = candidates.first(where: known.contains) { return hit }
        return candidates.first { MeetingSessionScanner.isSessionFolder(URL(fileURLWithPath: $0, isDirectory: true)) }
    }
```

- [ ] **Step 4: Run the index tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryIndexTests -only-testing:RogerTests/LibraryChangeRecorderTests 2>&1 | tail -20`
Expected: all pass (`changeLogFilesDoNotRescanTheLibrary` and `hiddenFilesAreIgnoredButHiddenExtraFoldersAreNot` still hold).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Library/LibraryIndex.swift Roger/RogerTests/LibraryIndexTests.swift
git commit -m "fix: update hidden files and meetings at any depth like the full scan"
```

---

### Task 5: Missing library root

When the library root does not exist, Roger does not watch a parent folder, the library window shows "Library folder not found" and Roger checks again when it becomes active and when the root setting changes (#13). Ruling 4: the change log never creates the root; Roger creates it at launch only when it is the default folder.

**Files:**
- Modify: `Roger/RogerKit/ChangeLog.swift` (`locked`)
- Modify: `Roger/RogerKit/LibraryLayout.swift` (`createRootIfDefault`)
- Modify: `Roger/Services/Library/LibraryIndex.swift` (protocol, root state, watched paths)
- Modify: `Roger/UI/Library/LibraryModel.swift` (`libraryMissing`, `recheckLibraryRoot`)
- Modify: `Roger/UI/Library/LibraryEmptyState.swift` (`make(...missingRoot:)`)
- Modify: `Roger/UI/Library/LibraryListView.swift` (overlay)
- Modify: `Roger/App/LibraryWindowController.swift` (recheck on activation)
- Modify: `Roger/App/RogerApp.swift:68-70`, `Roger/UI/RecordingsSettingsView.swift:43-45`
- Test: `Roger/RogerKitTests/ChangeLogTests.swift`, `Roger/RogerKitTests/ReconcileTests.swift`, new `Roger/RogerKitTests/LibraryLayoutRootTests.swift`
- Test: `Roger/RogerTests/LibraryIndexTests.swift`, `Roger/RogerTests/LibraryModelTests.swift`, `Roger/RogerTests/LibraryEmptyStateTests.swift`
- Regenerated: `Roger/Roger.xcodeproj` (new test file)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `LibraryLayout.createRootIfDefault(_ layout: LibraryLayout, defaultRoot: URL = LibraryLayout.defaultRoot) -> Bool` (public, `@discardableResult`).
  - `protocol LibraryIndex` gains `func libraryRootMissing() async -> Bool` and `func recheckRoot() async`, with defaults (`false`, nothing) in an extension, so test fakes need not implement them.
  - `InMemoryLibraryIndex.watchedPaths() -> [String]` (internal now, was private).
  - `LibraryModel.libraryMissing: Bool` (read-only), `LibraryModel.recheckLibraryRoot() async`.
  - `LibraryEmptyState.make(sidebar:searchText:dateFilter:missingRoot: URL? = nil)`.

- [ ] **Step 1: Write the failing RogerKit tests**

Add to `ChangeLogTests` in `Roger/RogerKitTests/ChangeLogTests.swift`:

```swift
    /// The root may be on a drive that is not connected: the log must not
    /// create it (or anything above it).
    @Test func changeLogNeverCreatesAMissingRoot() async throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let log = ChangeLog(root: base.appendingPathComponent("Drive/Roger", isDirectory: true))
        await #expect(throws: (any Error).self) { try await log.ensureFile() }
        await #expect(throws: (any Error).self) {
            try await log.append([PendingChange(event: .created, kind: .log, key: "Logs/x", path: "Logs/x.md")])
        }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Drive").path))
    }
```

Create `Roger/RogerKitTests/LibraryLayoutRootTests.swift`:

```swift
import Foundation
import Testing
@testable import RogerKit

struct LibraryLayoutRootTests {
    @Test func theDefaultRootIsCreated() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let root = base.appendingPathComponent("Documents/Roger", isDirectory: true)
        #expect(LibraryLayout.createRootIfDefault(LibraryLayout(root: root), defaultRoot: root))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func aMissingCustomRootIsLeftAlone() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let custom = base.appendingPathComponent("Volumes/Drive/Roger", isDirectory: true)
        let defaultRoot = base.appendingPathComponent("Documents/Roger", isDirectory: true)
        #expect(!LibraryLayout.createRootIfDefault(LibraryLayout(root: custom), defaultRoot: defaultRoot))
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Volumes").path))
    }

    @Test func anExistingCustomRootIsFine() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        #expect(LibraryLayout.createRootIfDefault(LibraryLayout(root: base), defaultRoot: base.appendingPathComponent("Other")))
    }
}
```

In `Roger/RogerKitTests/ReconcileTests.swift`, test `externalAndExtraFolderItemsGetExternalKeys`, the root `Library` was never created and the log used to create it. After the line `let layout = LibraryLayout(root: home.appendingPathComponent("Library", isDirectory: true))` add:

```swift
        // The change log never creates a missing root.
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
```

- [ ] **Step 2: Write the failing app tests**

Add to `LibraryIndexTests` in `Roger/RogerTests/LibraryIndexTests.swift`:

```swift
    /// A root on a drive that is not connected: no parent folder (it could
    /// be all of `~/Documents`) is watched in its place.
    @Test func aMissingRootIsReportedAndNotWatchedThroughItsParent() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let index = makeIndex(LibraryLayout(root: base.appendingPathComponent("Drive/Roger", isDirectory: true)))
        let missing = await index.libraryRootMissing()
        #expect(missing)
        #expect(await index.watchedPaths().isEmpty)
    }

    @Test func recheckFindsARootThatAppeared() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Drive/Roger", isDirectory: true))
        let index = makeIndex(layout)
        #expect(await index.items().isEmpty)
        try writeLog(layout, at: date, text: "Back again")
        await index.recheckRoot()
        let missing = await index.libraryRootMissing()
        #expect(!missing)
        #expect(await index.items().count == 1)
        #expect(await index.watchedPaths() == [LibraryPath.canonical(layout.root)])
    }
```

In `Roger/RogerTests/LibraryModelTests.swift`, give `FakeLibraryIndex` a switchable missing root. Add the stored property after `private var stored: [LibraryItem]`:

```swift
    private var missing = false
```

and after `func search(_ query: LibraryQuery) async -> [LibraryItem] { ... }`:

```swift
    func libraryRootMissing() async -> Bool { lock.withLock { missing } }

    func setMissing(_ value: Bool) {
        lock.withLock { missing = value }
    }
```

Then add to `LibraryModelTests`:

```swift
    @Test func aMissingLibraryFolderIsShownUntilItIsBack() async {
        let fake = FakeLibraryIndex([])
        fake.setMissing(true)
        let model = LibraryModel(index: fake)
        await model.reload()
        #expect(model.libraryMissing)
        fake.setMissing(false)
        await model.recheckLibraryRoot()
        #expect(!model.libraryMissing)
    }
```

In `Roger/RogerTests/LibraryEmptyStateTests.swift` add `import Foundation` above `import Testing` and add to the struct:

```swift
    @Test func aMissingLibraryFolderComesFirst() {
        let state = LibraryEmptyState.make(
            sidebar: .kind(.log), searchText: "supplier", dateFilter: .today,
            missingRoot: URL(fileURLWithPath: "/Volumes/Drive/Roger")
        )
        #expect(state.title == "Library folder not found")
        #expect(state.message == "Roger cannot find /Volumes/Drive/Roger. Connect the drive that holds it or choose another folder in Settings > Recordings.")
        #expect(!state.showsPresetsButton)
    }
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerKitTests/ChangeLogTests -only-testing:RogerKitTests/LibraryLayoutRootTests -only-testing:RogerTests/LibraryIndexTests -only-testing:RogerTests/LibraryModelTests -only-testing:RogerTests/LibraryEmptyStateTests 2>&1 | tail -30`
Expected: build FAILS (`createRootIfDefault`, `libraryRootMissing`, `watchedPaths`, `libraryMissing`, `missingRoot` do not exist).

- [ ] **Step 4: The change log never creates the root**

In `Roger/RogerKit/ChangeLog.swift`, replace the doc comment and first line of `locked(_:)`:

```swift
    /// Runs `decide` with all events under the lock and appends what it
    /// returns. `seq` continues after the highest valid seq in the file.
    /// When the file does not end with a newline (a crash cut the last
    /// line), one is written first so the new lines parse. Throws when the
    /// library root is not an existing folder: the log never creates the
    /// root (it may be on a drive that is not connected), only `.roger/`.
    func locked<T: Sendable>(
        _ decide: ([ChangeEvent]) throws -> ([PendingChange], T)
    ) throws -> (written: [ChangeEvent], result: T) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
```

(the rest of the function stays).

In `Roger/RogerKit/LibraryLayout.swift`, add before `public func kindFolder(_:)`:

```swift
    /// Creates the root when it is the default `~/Documents/Roger/` and
    /// does not exist yet (first launch). A custom root that is missing is
    /// left alone: it may be on a drive that is not connected. True when
    /// the root exists afterwards.
    @discardableResult
    public static func createRootIfDefault(_ layout: LibraryLayout, defaultRoot: URL = LibraryLayout.defaultRoot) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: layout.root.path) { return true }
        guard layout.root.standardizedFileURL.path == defaultRoot.standardizedFileURL.path else { return false }
        return (try? fm.createDirectory(at: layout.root, withIntermediateDirectories: true)) != nil
    }
```

- [ ] **Step 5: The index knows when its root is missing**

In `Roger/Services/Library/LibraryIndex.swift`:

Add to the protocol `LibraryIndex`, after `var changes: AsyncStream<Void> { get }`, and add the extension after the protocol:

```swift
    /// True when the library root is not a folder (deleted, or on a drive
    /// that is not connected).
    func libraryRootMissing() async -> Bool
    /// Looks at the root again; reads everything again when it appeared or
    /// went away.
    func recheckRoot() async
}

extension LibraryIndex {
    func libraryRootMissing() async -> Bool { false }
    func recheckRoot() async {}
}
```

In `InMemoryLibraryIndex`, add after `private var isBuilt = false`:

```swift
    /// Set by every full build: the root is not a folder.
    private var rootMissing = false
```

In `rebuild()`, right after `scanEventId = FSEventsGetCurrentEventId()`:

```swift
        rootMissing = !Self.isFolder(root)
```

Add before `// MARK: - Watching`. Both methods must be declared `async`: a synchronous actor method loses against the protocol extension's default when the call site has the concrete type (checked: the test then sees the default `false`).

```swift
    func libraryRootMissing() async -> Bool {
        buildIfNeeded()
        return rootMissing
    }

    /// Called when Roger becomes active: a root that appeared (a drive was
    /// connected) or went away is noticed without a file system event.
    func recheckRoot() async {
        guard isBuilt else { return }
        if Self.isFolder(root) == rootMissing { rebuild() }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
```

In `restartWatcherIfNeeded()`, after `tearDownWatcher()`:

```swift
        // Nothing to watch: a missing root and no other folders.
        guard !paths.isEmpty else { return }
```

Replace the doc comment and the first two lines of `watchedPaths()` (and drop `private`):

```swift
    /// The library root when it exists (never a parent: that could be all
    /// of `~/Documents`; a root that appears is found by `recheckRoot`), the
    /// extra folders, the folder of the external list and the folders of
    /// external transcripts. FSEvents watches each recursively, so new
    /// `YYYY/MM` folders are covered.
    func watchedPaths() -> [String] {
        var urls: [URL] = rootMissing ? [] : [scope.layout.root]
        urls += scope.extraFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
```

- [ ] **Step 6: The model and the empty state**

In `Roger/UI/Library/LibraryModel.swift`, after `private(set) var isLoading = true`:

```swift
    /// The library folder does not exist (deleted, or on a drive that is
    /// not connected).
    private(set) var libraryMissing = false
```

In `reload()`, after `let found = await index.search(query)`:

```swift
        let missing = await index.libraryRootMissing()
```

and after `totalCount = all.count`:

```swift
        libraryMissing = missing
```

Add before `func commitSearch()`:

```swift
    /// Roger became active: the library folder may have come back.
    func recheckLibraryRoot() async {
        await index.recheckRoot()
        await reload()
    }
```

In `Roger/UI/Library/LibraryEmptyState.swift`, replace the signature and first lines of `make`:

```swift
    /// `missingRoot` is the library folder when it does not exist; that
    /// comes before everything else.
    static func make(
        sidebar: LibrarySidebarSelection,
        searchText: String,
        dateFilter: LibraryDateFilter,
        missingRoot: URL? = nil
    ) -> LibraryEmptyState {
        if let missingRoot {
            return .init(title: "Library folder not found",
                         message: "Roger cannot find \(missingRoot.path). Connect the drive that holds it or choose another folder in Settings > Recordings.",
                         systemImage: "folder.badge.questionmark", showsPresetsButton: false)
        }
        if !searchText.isEmpty {
```

In `Roger/UI/Library/LibraryListView.swift`, in `overlay`, pass the root:

```swift
            LibraryEmptyStateView(state: LibraryEmptyState.make(
                sidebar: model.sidebar,
                searchText: model.appliedSearch,
                dateFilter: model.dateFilter,
                missingRoot: model.libraryMissing ? coordinator.appState.libraryLayout.root : nil
            ))
```

- [ ] **Step 7: Recheck on activation, create the default root at launch**

In `Roger/App/LibraryWindowController.swift`, add a property after `private(set) var isOpen = false`:

```swift
    private var activationObserver: NSObjectProtocol?
```

and at the end of `init(coordinator:indexStore:)`, after the two assignments (the closure captures `self`, so `super.init()` must come first; it was implicit before):

```swift
        super.init()
        // A library folder on a drive that was connected meanwhile, or
        // one that was deleted: look again whenever Roger becomes active.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, let model = self.model else { return }
                Task { await model.recheckLibraryRoot() }
            }
        }
```

(A root setting change already gives a new index through `refreshScope()`, which builds and checks the root on first use.)

In `Roger/App/RogerApp.swift`, `applicationDidFinishLaunching`, replace the reconcile lines:

```swift
        // Fill or catch up the change log agents read (after the migration,
        // so moved meetings get their library keys). The change log never
        // creates the root; the default one is created here on first launch.
        LibraryLayout.createRootIfDefault(coordinator.appState.libraryLayout)
        coordinator.libraryChanges.reconcile()
```

In `Roger/UI/RecordingsSettingsView.swift`, the Reset button:

```swift
                                Button("Reset") {
                                    state.libraryRoot = nil
                                    LibraryLayout.createRootIfDefault(state.libraryLayout)
                                    coordinator.libraryChanges.reconcile()
                                }
```

(`state` is the view's `@Bindable var state = coordinator.appState`.)

- [ ] **Step 8: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -30`
Expected: all pass. `LibraryChangeRecorderTests` still pass: where a test calls `reconcile()` before the root exists, the catch-up now fails with a logged warning and the later `recordWritten` calls still write.

- [ ] **Step 9: Manual check**

Debug-run Roger with a library folder on a USB stick (Settings > Recordings > Choose...), quit, eject the stick, start Roger, open the library: the list says "Library folder not found" and no folder was created under `/Volumes`. Plug the stick in, click another app and back on Roger: the entries appear.

- [ ] **Step 10: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/RogerKit/ChangeLog.swift Roger/RogerKit/LibraryLayout.swift Roger/Services/Library/LibraryIndex.swift Roger/UI/Library/LibraryModel.swift Roger/UI/Library/LibraryEmptyState.swift Roger/UI/Library/LibraryListView.swift Roger/App/LibraryWindowController.swift Roger/App/RogerApp.swift Roger/UI/RecordingsSettingsView.swift Roger/RogerKitTests/ChangeLogTests.swift Roger/RogerKitTests/ReconcileTests.swift Roger/RogerKitTests/LibraryLayoutRootTests.swift Roger/RogerTests/LibraryIndexTests.swift Roger/RogerTests/LibraryModelTests.swift Roger/RogerTests/LibraryEmptyStateTests.swift Roger/Roger.xcodeproj
git commit -m "fix: show a missing library folder instead of watching its parent"
```

---

### Task 6: Unfinished meetings show their chunks, and a deterministic store test

Unfinished meetings with only audio chunks count the chunks as audio, and their screenshots are counted even without `markers.json` (Ruling 6). `scopeChangeStopsTheOldIndex` waits for the stop task instead of a fixed number of yields (#13).

**Files:**
- Modify: `Roger/RogerKit/LibraryItemReader.swift` (`meetingItem(sessionFolder:)`, unfinished branch)
- Modify: `Roger/Services/Library/LibraryIndexStore.swift`
- Test: new `Roger/RogerKitTests/UnfinishedMeetingItemTests.swift`
- Test: `Roger/RogerTests/LibraryIndexStoreTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `ItemResolver.imageExtensions` (existing, RogerKit).
- Produces: `LibraryIndexStore.stopping: Task<Void, Never>?` (read-only).

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerKitTests/UnfinishedMeetingItemTests.swift`:

```swift
import Foundation
import Testing
@testable import RogerKit

/// An unfinished meeting that only has its recording chunks (a crash
/// before finalisation) shows its audio and its screenshots.
struct UnfinishedMeetingItemTests {
    private func session(_ base: URL, files: [String]) throws -> URL {
        let folder = base.appendingPathComponent("2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try Data().write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    @Test func chunksCountAsAudio() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["system-001.caf", "mic-002.caf", "mic-001.caf", ".mic-003.caf"])
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.isUnfinished)
        #expect(item.hasAudio)
        #expect(item.audioFiles.map(\.lastPathComponent) == ["mic-001.caf", "mic-002.caf", "system-001.caf"])
    }

    @Test func archivesComeBeforeChunks() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["mic-001.caf", "system.m4a"])
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.audioFiles.map(\.lastPathComponent) == ["system.m4a", "mic-001.caf"])
    }

    @Test func screenshotsAreCountedWithoutMarkers() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["mic-001.caf", "2026-10-13 09-05-00.png", "2026-10-13 09-10-00.PNG", "notes.txt"])
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.screenshotCount == 2)
    }

    @Test func markersWinOverTheFolderCount() throws {
        let base = try TempDir.make()
        defer { TempDir.remove(base) }
        let folder = try session(base, files: ["mic-001.caf", "a.png", "b.png"])
        let json = #"{"markers":[{}],"sessionStartedAt":"2026-10-13T07:00:00Z","version":1}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("markers.json"))
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.screenshotCount == 1)
    }
}
```

In `Roger/RogerTests/LibraryIndexStoreTests.swift`, replace the body of `scopeChangeStopsTheOldIndex` after `_ = store.index(for: scope("/RogerFixtures/B"))`:

```swift
        // The store stops the old index in a task; wait for exactly that task.
        await store.stopping?.value
        #expect(await a.watchingStopped)
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerKitTests/UnfinishedMeetingItemTests -only-testing:RogerTests/LibraryIndexStoreTests 2>&1 | tail -30`
Expected: build FAILS (`stopping` does not exist). Without that test, `chunksCountAsAudio`, `archivesComeBeforeChunks` and `screenshotsAreCountedWithoutMarkers` fail.

- [ ] **Step 3: Read chunks and screenshots of an unfinished meeting**

In `Roger/RogerKit/LibraryItemReader.swift`, `meetingItem(sessionFolder:)`, replace the `audio` constant after `let title = ...`:

```swift
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        // The archives of an earlier run, then the CAF chunks of the recording.
        let archives = ["mic.m4a", "system.m4a"].filter { names.contains($0) }
        let chunks = names.filter { $0.lowercased().hasSuffix(".caf") }.sorted()
        let audio = (archives + chunks).map { folder.appendingPathComponent($0) }
        // Without markers.json the screenshots in the folder are counted.
        let screenshots = markers?.markerCount
            ?? names.filter { ItemResolver.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count
```

and in the `LibraryItem(...)` call below it:

```swift
            screenshotCount: screenshots,
```

- [ ] **Step 4: Keep the stop task**

In `Roger/Services/Library/LibraryIndexStore.swift`, after `private(set) var current: InMemoryLibraryIndex?`:

```swift
    /// Stops the index a scope change replaced. Tests wait for it.
    private(set) var stopping: Task<Void, Never>?
```

and in `index(for:)`:

```swift
        if let old = current {
            stopping = Task { await old.stopWatching() }
        }
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass (`LibraryItemReaderTests.unfinishedSessionWithoutTranscript` too).

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/RogerKit/LibraryItemReader.swift Roger/Services/Library/LibraryIndexStore.swift Roger/RogerKitTests/UnfinishedMeetingItemTests.swift Roger/RogerTests/LibraryIndexStoreTests.swift Roger/Roger.xcodeproj
git commit -m "fix: show audio chunks and screenshots of unfinished meetings"
```

---

### Task 7: Title sort by row text, and no filters for Unfinished

Title sort orders log entries by the text their rows show, not by the hidden "Log <date> <time>" title. While Unfinished is selected, search, the date filter and sort are disabled (#12, Ruling 10).

**Files:**
- Modify: `Roger/Services/Library/LibraryQuery.swift` (`sorted`, case `.title`)
- Modify: `Roger/UI/Library/LibraryModel.swift` (`LibrarySidebarSelection.usesFilters`)
- Modify: `Roger/UI/Library/LibraryView.swift`
- Test: `Roger/RogerTests/LibraryQueryTests.swift`

**Interfaces:**
- Consumes: `LibraryFormat.rowText(for:)` (existing, `Roger/Services/Library/LibraryDayGrouping.swift`).
- Produces: `LibrarySidebarSelection.usesFilters: Bool`.

- [ ] **Step 1: Write the failing tests**

In `Roger/RogerTests/LibraryQueryTests.swift`, `sortOrders` uses log items with an empty body, whose rows all read "Empty log entry". Make them transcripts so the test still checks the title order. Replace its `items`:

```swift
        // Transcripts: their rows show the title (log rows show their text).
        let items = [
            LibraryFixtures.item("Log 10", kind: .transcript, date: LibraryFixtures.date(2026, 10, 2), duration: 30),
            LibraryFixtures.item("Log 2", kind: .transcript, date: LibraryFixtures.date(2026, 10, 3), duration: nil),
            LibraryFixtures.item("Log 1", kind: .transcript, date: LibraryFixtures.date(2026, 10, 1), duration: 90),
        ]
```

Add to `LibraryQueryTests`:

```swift
    /// Log rows show their text, so title sort orders logs by that text.
    @Test func titleSortUsesTheRowTextOfLogs() {
        let zebra = LibraryFixtures.item("a", kind: .log, title: "Log 2026-10-13 09:00 - Zebra crossing", body: "Zebra crossing")
        let apple = LibraryFixtures.item("b", kind: .log, title: "Log 2026-10-13 10:00 - Apple pie", body: "Apple pie")
        let meeting = LibraryFixtures.item("c", kind: .meeting, title: "Meeting notes", body: "Budget")
        let empty = LibraryFixtures.item("d", kind: .log, title: "Log 2026-10-13 11:00", body: "")
        let sorted = LibraryQuery.sorted([zebra, apple, meeting, empty], by: .title)
        #expect(sorted.map(\.id) == [apple.id, empty.id, meeting.id, zebra.id])
    }

    @Test func unfinishedHasNoFilters() {
        #expect(!LibrarySidebarSelection.unfinished.usesFilters)
        #expect(LibrarySidebarSelection.all.usesFilters)
        #expect(LibrarySidebarSelection.kind(.log).usesFilters)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryQueryTests 2>&1 | tail -20`
Expected: build FAILS (`usesFilters` does not exist); without that test, `titleSortUsesTheRowTextOfLogs` fails.

- [ ] **Step 3: Sort titles by row text**

In `Roger/Services/Library/LibraryQuery.swift`, `sorted(_:by:)`, case `.title`:

```swift
            case .title:
                // What the row shows: a log's text, not its hidden "Log <date> <time>" title.
                let order = LibraryFormat.rowText(for: a).title.localizedStandardCompare(LibraryFormat.rowText(for: b).title)
                if order != .orderedSame { return order == .orderedAscending }
                return a.date != b.date ? a.date > b.date : a.id < b.id
```

- [ ] **Step 4: Unfinished has no filters**

In `Roger/UI/Library/LibraryModel.swift`, extend `LibrarySidebarSelection`:

```swift
    /// `AppCoordinator.pendingMeetingSessions`, not index items.
    case unfinished

    /// Search, the date filter and sort apply to this list. Unfinished
    /// meetings are a plain list without them.
    var usesFilters: Bool { self != .unfinished }
}
```

In `Roger/UI/Library/LibraryView.swift`, replace the `.searchable`, `.toolbar` and the Find button:

```swift
        .searchable(
            text: searchBinding,
            placement: .toolbar,
            prompt: model.sidebar.usesFilters ? "Search titles and text" : "Search is off for Unfinished"
        )
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItemGroup {
                LibraryDateFilterMenu(model: model)
                    .disabled(!model.sidebar.usesFilters)
                LibrarySortMenu(model: model)
                    .disabled(!model.sidebar.usesFilters)
            }
        }
        .background {
            // Cmd-F focuses the search field. The default Find menu item is
            // not wired to `.searchable` in an AppKit-hosted window.
            Button("Find") { if model.sidebar.usesFilters { searchFocused = true } }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
```

and add to `LibraryView`:

```swift
    /// SwiftUI cannot disable a toolbar search field. While Unfinished is
    /// selected the field shows nothing and ignores input; the search of
    /// the other lists is kept for when the user goes back.
    private var searchBinding: Binding<String> {
        Binding(
            get: { model.sidebar.usesFilters ? model.searchText : "" },
            set: { if model.sidebar.usesFilters { model.searchText = $0 } }
        )
    }
```

- [ ] **Step 5: Run the tests and build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryQueryTests -only-testing:RogerTests/LibraryModelTests 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 6: Manual check**

Debug-run Roger, open the library with a search typed in: select Unfinished. The date and sort buttons are grey, the search field is empty and shows "Search is off for Unfinished", typing does nothing. Select All again: the old search text is back.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Library/LibraryQuery.swift Roger/UI/Library/LibraryModel.swift Roger/UI/Library/LibraryView.swift Roger/RogerTests/LibraryQueryTests.swift
git commit -m "fix: sort logs by their text and turn off filters for unfinished meetings"
```

---

### Task 8: Rename commits like Finder, and saved entries update and stay at once

A click elsewhere commits the new name, Esc cancels. After a rename or a save the header and the row update at once from the saved file. After a save the entry stays listed and selected until another entry is selected (#12, Rulings 9 and 11).

**Files:**
- Create: `Roger/UI/Library/LibraryRenameState.swift`
- Modify: `Roger/Services/Library/LibraryIndex.swift` (protocol `refresh(paths:)`)
- Modify: `Roger/UI/Library/LibraryModel.swift` (pin, `didWrite`)
- Modify: `Roger/UI/Library/LibraryDetailView.swift` (`LibraryItemDetail`)
- Test: new `Roger/RogerTests/LibraryRenameStateTests.swift`, `Roger/RogerTests/LibraryModelTests.swift`, `Roger/RogerTests/LibraryIndexTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryIndex.libraryRootMissing()`/`recheckRoot()` defaults (Task 5).
- Produces:
  - `struct LibraryRenameState: Equatable, Sendable { private(set) var isActive: Bool; var draft: String; mutating func begin(title: String); mutating func commit() -> String?; mutating func cancel() }`.
  - `protocol LibraryIndex` gains `func refresh(paths: [String]) async` (default: nothing); `InMemoryLibraryIndex.refresh(paths:)` calls `apply(changedPaths:)`.
  - `LibraryModel.didWrite(_ item: LibraryItem) async`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/LibraryRenameStateTests.swift`:

```swift
import Testing
@testable import Roger

struct LibraryRenameStateTests {
    @Test func commitHappensOnce() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "New"
        #expect(rename.commit() == "New")   // Return
        #expect(rename.commit() == nil)     // the focus loss that follows
        #expect(!rename.isActive)
    }

    @Test func cancelThenFocusLossCommitsNothing() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "New"
        rename.cancel()                     // Esc
        #expect(rename.commit() == nil)     // the focus loss that follows
    }

    @Test func anUnchangedTitleIsNotWritten() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        #expect(rename.commit() == nil)
    }

    @Test func aNewRenameStartsFromTheCurrentTitle() {
        var rename = LibraryRenameState()
        rename.begin(title: "Old")
        rename.draft = "Typed"
        rename.cancel()
        rename.begin(title: "Current")
        #expect(rename.draft == "Current")
        rename.draft = "Next"
        #expect(rename.commit() == "Next")
    }

    @Test func nothingHappensWithoutARename() {
        var rename = LibraryRenameState()
        #expect(rename.commit() == nil)
    }
}
```

In `Roger/RogerTests/LibraryModelTests.swift`, let `FakeLibraryIndex` record refreshes. Add after `private var missing = false`:

```swift
    private var refreshed: [String] = []
```

and before `func setMissing(_:)`:

```swift
    func refresh(paths: [String]) async { lock.withLock { refreshed += paths } }
    var refreshedPaths: [String] { lock.withLock { refreshed } }
```

Add to `LibraryModelTests`:

```swift
    /// After a save the entry stays listed and selected although the new
    /// text no longer matches the search, until another entry is selected.
    @Test func aSavedEntryStaysListedUntilAnotherIsSelected() async throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let file = folder.appendingPathComponent("note.md")
        try "---\ntitle: \"note\"\n---\n# note\nsupplier call\n".write(to: file, atomically: true, encoding: .utf8)
        let note = LibraryFixtures.item("note", body: "supplier call", folder: folder.path)
        let other = LibraryFixtures.item("other", body: "supplier invoice")
        let fake = FakeLibraryIndex([note, other])
        let model = LibraryModel(index: fake)
        model.searchText = "supplier"
        await model.commitSearch()
        model.selection = [note.id]

        model.beginEditing(note, document: try LibraryDocument.load(file))
        model.draft = "# note\nwarehouse visit\n"
        #expect(try model.saveEdit(overwrite: false, activeSessionFolder: nil) == .saved)
        let saved = LibraryFixtures.item("note", body: "warehouse visit", folder: folder.path)
        fake.set([saved, other])
        await model.reload()
        #expect(model.results.map(\.id).contains(note.id))
        #expect(model.results.first { $0.id == note.id }?.firstLine == "warehouse visit")
        #expect(model.selection == [note.id])

        model.selection = [other.id]
        await model.reload()
        #expect(model.results.map(\.id) == [other.id])
        model.stop()
    }

    @Test func didWriteRefreshesTheIndexAndKeepsTheEntry() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        model.sidebar = .kind(.meeting)
        await model.reload()
        model.selection = [items[0].id]
        await model.didWrite(items[0])
        #expect(fake.refreshedPaths == [items[0].url.path])
        #expect(Set(model.results.map(\.id)) == [items[0].id, items[2].id])
        #expect(model.selection == [items[0].id])
    }

    @Test func aPinnedEntryThatIsGoneIsDropped() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        model.sidebar = .kind(.meeting)
        model.selection = [items[0].id]
        await model.didWrite(items[0])
        fake.set([items[2]])
        await model.reload()
        #expect(model.results.map(\.id) == [items[2].id])
        #expect(model.selection.isEmpty)
    }
```

Add to `LibraryIndexTests`:

```swift
    /// After a rename the index reads the file at once, not when the folder
    /// watcher reports it.
    @Test func refreshReadsAFileNow() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let url = try writeLog(layout, at: date, text: "Before")
        let index = makeIndex(layout)
        #expect(await index.items().first?.firstLine == "Before")
        try writeLog(layout, at: date, text: "After")
        await index.refresh(paths: [url.path])
        #expect(await index.items().first?.firstLine == "After")
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryRenameStateTests -only-testing:RogerTests/LibraryModelTests -only-testing:RogerTests/LibraryIndexTests 2>&1 | tail -30`
Expected: build FAILS (`LibraryRenameState`, `didWrite`, `refresh(paths:)` do not exist).

- [ ] **Step 3: The rename state**

Create `Roger/UI/Library/LibraryRenameState.swift`:

```swift
import Foundation

/// One rename in the detail header. It ends once: Return, the focus
/// leaving the field or a click elsewhere commit it, Esc cancels it. What
/// comes after the end (the focus loss that follows Return or Esc) does
/// nothing, so a title is never written twice and Esc never writes.
struct LibraryRenameState: Equatable, Sendable {
    private(set) var isActive = false
    /// What the text field shows.
    var draft = ""
    private var original = ""

    mutating func begin(title: String) {
        isActive = true
        draft = title
        original = title
    }

    /// The title to write, or nil: not renaming, ended already or unchanged.
    mutating func commit() -> String? {
        guard isActive else { return nil }
        isActive = false
        return draft == original ? nil : draft
    }

    mutating func cancel() {
        isActive = false
    }
}
```

- [ ] **Step 4: The index reads written files at once**

In `Roger/Services/Library/LibraryIndex.swift`, add to the protocol after `func recheckRoot() async`:

```swift
    /// Reads these files again now, without waiting for the folder watcher
    /// (after Roger wrote them).
    func refresh(paths: [String]) async
```

and to the protocol extension:

```swift
    func refresh(paths: [String]) async {}
```

In `InMemoryLibraryIndex`, before `func apply(changedPaths:)` (declared `async`, see Task 5 Step 5):

```swift
    func refresh(paths: [String]) async {
        apply(changedPaths: paths)
    }
```

- [ ] **Step 5: The model pins the written entry**

In `Roger/UI/Library/LibraryModel.swift`:

Replace `var selection: Set<LibraryItem.ID> = []` with:

```swift
    var selection: Set<LibraryItem.ID> = [] {
        didSet {
            // Selecting anything else ends the pin.
            if let pinnedID, selection != [pinnedID] { self.pinnedID = nil }
        }
    }
```

After `@ObservationIgnored private var pendingSelectionID: String?`:

```swift
    /// The entry that was just saved or renamed. It stays in `results`
    /// (and selected) even when it no longer matches the search or the
    /// filters, until the selection changes.
    @ObservationIgnored private var pinnedID: String?
```

In `saveEdit(overwrite:activeSessionFolder:)`, case `.saved`:

```swift
        case .saved:
            pinnedID = item.id
            editingItem = nil
            return .saved
```

Before `func recheckLibraryRoot()`:

```swift
    /// Roger wrote this entry's file (rename or save). The index reads it
    /// now, so the header and the row show the new text at once, and the
    /// entry stays listed and selected.
    func didWrite(_ item: LibraryItem) async {
        pinnedID = item.id
        await index.refresh(paths: [item.url.path])
        await reload()
    }
```

In `reload()`, replace from `libraryMissing = missing` through `let ids = Set(found.map(\.id))`:

```swift
        libraryMissing = missing
        var shown = found
        if let pinned = pinnedID, !found.contains(where: { $0.id == pinned }) {
            if let item = all.first(where: { $0.id == pinned }) {
                shown = LibraryQuery.sorted(found + [item], by: query.sort)
            } else {
                // Gone from the index (moved or deleted).
                pinnedID = nil
            }
        }
        results = shown
        isLoading = false
        let ids = Set(shown.map(\.id))
```

- [ ] **Step 6: The detail header**

In `Roger/UI/Library/LibraryDetailView.swift`, `LibraryItemDetail`:

Replace `@State private var isRenaming = false` and `@State private var titleDraft = ""` with:

```swift
    @State private var rename = LibraryRenameState()
```

In `body`, replace the editor/preview part below the `Divider()`:

```swift
            Divider()
            Group {
                if model.isEditing {
                    TextEditor(text: $model.draft)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                } else {
                    preview
                }
            }
            // A click below the header ends a rename, like in Finder.
            .simultaneousGesture(TapGesture().onEnded { endRenameByClick() })
```

and add after `.onChange(of: model.renameRequest) { _, _ in consumeRenameRequest() }`:

```swift
        .onChange(of: titleFocused) { _, focused in
            // Focus moved away (a click in the list, the sidebar or the
            // search field): commit, like Finder. After Return or Esc this
            // does nothing.
            if !focused { commitRename() }
        }
```

In `header`, replace the `if isRenaming { ... }` branch:

```swift
            if rename.isActive {
                TextField("Title", text: $rename.draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { rename.cancel() }
            } else {
```

In `startEditing()`, replace `isRenaming = false` with `rename.cancel()`.

In `save(overwrite:)`, case `.saved`:

```swift
            case .saved:
                coordinator.libraryChanges.recordWritten(markdownURL: item.url, kind: item.kind)
                // The new modification date, or the next save sees this
                // write as a change by another app.
                reloadNow()
                let written = item
                Task { await model.didWrite(written) }
```

Replace `startRename()` and `commitRename()`, and add `endRenameByClick()`:

```swift
    private func startRename() {
        guard canEdit, !model.isEditing else { return }
        rename.begin(title: item.title)
        titleFocused = true
    }

    private func endRenameByClick() {
        guard rename.isActive else { return }
        commitRename()
        titleFocused = false
    }

    /// Checks the active meeting folder again, like `save`: a recording
    /// may have started in this folder since the rename began. Runs at
    /// most once per rename (`LibraryRenameState`).
    private func commitRename() {
        guard let title = rename.commit() else { return }
        guard canEdit else {
            actionError = LibraryModel.EditSaveOutcome.notEditable.failureMessage
            return
        }
        do {
            try LibraryDocumentEditor.rename(fileAt: item.url, to: title)
            coordinator.libraryChanges.recordWritten(markdownURL: item.url, kind: item.kind)
            reloadNow()
            let written = item
            Task { await model.didWrite(written) }
        } catch {
            actionError = error.localizedDescription
        }
    }
```

- [ ] **Step 7: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 8: Manual check**

Debug-run Roger, open the library:
1. Click a title, type a new one, click into the text below: the header shows the new title at once and so does the row (no half-second wait).
2. Click a title, type, press Esc, then click the list: nothing is renamed.
3. Click a title, type, press Return, then click the list: `<library>/.roger/changes.jsonl` got exactly one new `updated` line for the entry.
4. Search for a word, edit the selected entry so the word is gone, Save: the entry stays in the list and selected with its new text. Select another entry: the edited one leaves the list.

- [ ] **Step 9: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/UI/Library/LibraryRenameState.swift Roger/Services/Library/LibraryIndex.swift Roger/UI/Library/LibraryModel.swift Roger/UI/Library/LibraryDetailView.swift Roger/RogerTests/LibraryRenameStateTests.swift Roger/RogerTests/LibraryModelTests.swift Roger/RogerTests/LibraryIndexTests.swift Roger/Roger.xcodeproj
git commit -m "fix: commit renames on click elsewhere and show saved entries at once"
```

---

### Task 9: Extra files with subfolders, live refresh and the Clean Up message

A meeting folder with a subfolder shows the Extra files section; a subfolder is one row that can be revealed but not trashed (Ruling 8). The section lists its folder again when the index reports a change there (Ruling 7). Clean Up says why when it refuses because a retry started while the dialog was open (#12).

**Files:**
- Modify: `Roger/Services/MeetingRecording/MeetingExtraFiles.swift`
- Modify: `Roger/Services/Library/LibraryActions.swift` (`isRogerSessionFolder`, `listsExtraFiles`, new message)
- Modify: `Roger/Services/Library/LibraryIndex.swift` (`apply`, change counter)
- Modify: `Roger/UI/Library/LibraryModel.swift` (`reloadCount`)
- Modify: `Roger/UI/Library/LibraryExtraFilesSection.swift`, `Roger/UI/Library/LibraryDetailView.swift` (pass `reloadCount`)
- Test: `Roger/RogerTests/MeetingExtraFilesTests.swift`, `Roger/RogerTests/LibraryActionsTests.swift`, `Roger/RogerTests/LibraryIndexTests.swift`, `Roger/RogerTests/LibraryModelTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `MeetingExtraFiles.Kind.subfolder` (raw value `"subfolder"`, last case), `MeetingExtraFiles.Kind.isTrashable: Bool`.
  - `LibraryActions.isRogerSessionFolder(_:layout:extraFolders:allowsSubfolders: Bool = false)`.
  - `LibraryActions.extraFilesBusyMessage: String`.
  - `InMemoryLibraryIndex.changeCount: Int` (read-only, counts yields).
  - `LibraryModel.reloadCount: Int` (read-only).
  - `LibraryExtraFilesSection(item:reloadCount:)`.

- [ ] **Step 1: Write the failing tests**

Add to `MeetingExtraFilesTests` in `Roger/RogerTests/MeetingExtraFilesTests.swift`:

```swift
    /// A subfolder is one row that is never trashable, also when its name
    /// looks like an extra file. It is no audio source.
    @Test func subfoldersAreListedButNeverTrashable() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, ["transcript.md", "mic.leftover.m4a"])
        for name in ["Slides", "mic.previous.m4a", ".hidden"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let found = MeetingExtraFiles.find(in: folder)
        #expect(found.map(\.url.lastPathComponent) == ["mic.leftover.m4a", "Slides", "mic.previous.m4a"])
        #expect(found.map(\.kind.isTrashable) == [true, false, false])
        #expect(MeetingExtraFiles.audioSources(in: folder).map(\.resource) == ["mic.leftover.m4a"])
    }
```

Add to `LibraryActionsTests`:

```swift
    /// The Extra files section shows up for a session folder with a
    /// subfolder, but the whole meeting still does not go to the Trash.
    @Test func aSessionWithASubfolderListsExtraFilesButIsNotTrashed() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let library = layout(root.appendingPathComponent("Roger"))
        let session = library.root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        try meetingTranscript(in: session)
        try FileManager.default.createDirectory(at: session.appendingPathComponent("Slides"), withIntermediateDirectories: true)
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        #expect(LibraryActions.listsExtraFiles(item, layout: library, extraFolders: []))
        let plan = LibraryActions.trashPlan(for: [item], layout: library, extraFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])
    }
```

Add to `LibraryIndexTests`:

```swift
    /// A leftover file appearing in a meeting folder does not change the
    /// meeting item, but the change is still reported (Extra files).
    @Test func aChangeInsideAMeetingFolderIsReported() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "Hello")
        let index = makeIndex(layout)
        let before = await index.items()
        let reported = await index.changeCount
        let leftover = folder.appendingPathComponent("mic.leftover.m4a")
        try Data().write(to: leftover)
        await index.apply(changedPaths: [leftover.path])
        #expect(await index.items() == before)
        #expect(await index.changeCount == reported + 1)
    }
```

Add to `LibraryModelTests`:

```swift
    @Test func everyAppliedReloadIsCounted() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        #expect(model.reloadCount == 0)
        await model.reload()
        await model.reload()
        #expect(model.reloadCount == 2)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/MeetingExtraFilesTests -only-testing:RogerTests/LibraryActionsTests -only-testing:RogerTests/LibraryIndexTests -only-testing:RogerTests/LibraryModelTests 2>&1 | tail -30`
Expected: build FAILS (`isTrashable`, `changeCount`, `reloadCount` do not exist).

- [ ] **Step 3: Subfolders in MeetingExtraFiles**

In `Roger/Services/MeetingRecording/MeetingExtraFiles.swift`:

Replace the type comment:

```swift
/// Files a retry can leave in a meeting folder: leftover and previous
/// audio archives, the previous transcript and previous segments. Also
/// the folder's subfolders, which Roger never writes: they are listed so
/// the user sees them, but never moved. Nothing here moves or deletes.
```

Replace the end of `Kind` from `case segmentPrevious = "segment-previous"` through `isAudio`:

```swift
        case segmentPrevious = "segment-previous"
        /// A folder inside the meeting folder (also one named like an extra file).
        case subfolder = "subfolder"

        var isAudio: Bool {
            switch self {
            case .micLeftover, .systemLeftover, .micPrevious, .systemPrevious: return true
            case .transcriptPrevious, .segmentPrevious, .subfolder: return false
            }
        }

        /// Clean Up and the row's Trash button may move it. Folders never.
        var isTrashable: Bool { self != .subfolder }
```

Replace the head of `find(in:)` up to the `.sorted` call:

```swift
    /// Extra files and subfolders in `folder` (hidden names left out),
    /// ordered by kind, then number, then name. A directory is always a
    /// `.subfolder`, whatever its name.
    static func find(in folder: URL) -> [File] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let order = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { name in
                let url = folder.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                // fileExists follows symlinks, so a link to a folder counts as one.
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return File(url: url, kind: .subfolder, number: 0)
                }
                return classify(name).map { File(url: url, kind: $0.kind, number: $0.number) }
            }
```

(`audioSources(in:)` filters `isAudio`, so meeting transcripts never list a subfolder in `sources`.)

- [ ] **Step 4: List extra files of a session folder with subfolders**

In `Roger/Services/Library/LibraryActions.swift`, replace the last two bullets of the `isRogerSessionFolder` doc comment and its signature:

```swift
    /// - it holds session files and no subfolders (Roger writes sessions
    ///   flat). `allowsSubfolders` drops this rule for listing extra files:
    ///   the section shows subfolders but never moves them;
    /// - it neither is nor contains the library root, a kind folder or an
    ///   extra folder.
    /// Anything else is not a session folder, so nothing in it is moved.
    static func isRogerSessionFolder(
        _ folderURL: URL,
        layout: LibraryLayout,
        extraFolders: [URL],
        allowsSubfolders: Bool = false
    ) -> Bool {
```

and its last line:

```swift
            && (allowsSubfolders || !hasSubfolder(folderURL))
```

Replace `listsExtraFiles` and add the message after it:

```swift
    static func listsExtraFiles(_ item: LibraryItem, layout: LibraryLayout, extraFolders: [URL]) -> Bool {
        guard item.kind == .meeting, item.hasMarkdown else { return false }
        return ownsSessionFolder(item, folder: LibraryPath.canonical(item.folderURL))
            && isRogerSessionFolder(item.folderURL, layout: layout, extraFolders: extraFolders, allowsSubfolders: true)
    }

    /// What the Extra files section says when it moved nothing because the
    /// meeting got busy: it is being recorded or finalised, or a retry
    /// started while the question was open.
    static let extraFilesBusyMessage = "Roger did not move these files. This meeting is busy right now or waits for a retry. Try again when it is done."
```

- [ ] **Step 5: The index reports changes inside meeting folders**

In `Roger/Services/Library/LibraryIndex.swift`, `InMemoryLibraryIndex`, after `private var isBuilt = false`:

```swift
    /// How often `changes` yielded. For tests: a missing yield would make
    /// them wait forever on the stream.
    private(set) var changeCount = 0
```

In `rebuild()` replace `continuation.yield()` with `notifyChange()`. In `apply(changedPaths:)` replace the last line `if itemsByID != before { continuation.yield() }` with:

```swift
        // A change inside a meeting folder is reported even when the meeting
        // item stayed the same: the Extra files section lists the folder again.
        let touchedSession = units.contains { if case .session = $0 { return true } else { return false } }
        if itemsByID != before || touchedSession { notifyChange() }
    }

    private func notifyChange() {
        changeCount += 1
        continuation.yield()
    }
```

(the closing brace above ends `apply`; do not add a second one).

In `Roger/UI/Library/LibraryModel.swift`, after `private(set) var appliedSearch = ""`:

```swift
    /// Grows with every reload that was applied. The Extra files section
    /// lists its folder again when it changes.
    private(set) var reloadCount = 0
```

and in `reload()`, after `lastAppliedReload = reloadNumber`:

```swift
        reloadCount += 1
```

- [ ] **Step 6: The section**

In `Roger/UI/Library/LibraryDetailView.swift`, `preview`, pass the counter:

```swift
                    if item.kind == .meeting {
                        LibraryExtraFilesSection(item: item, reloadCount: model.reloadCount)
                    }
```

In `Roger/UI/Library/LibraryExtraFilesSection.swift`:

Add after `let item: LibraryItem`:

```swift
    /// `LibraryModel.reloadCount`: the folder is listed again when it changes.
    let reloadCount: Int
```

Add after `mayTrash`:

```swift
    /// What Clean Up and the Trash buttons may move (never a folder).
    private var trashable: [MeetingExtraFiles.File] { files.filter(\.kind.isTrashable) }
```

Replace the header `HStack`, the caption and the row `ForEach`:

```swift
                    HStack {
                        Text("Extra files")
                            .font(.headline)
                        Spacer()
                        if !item.isUnfinished, !trashable.isEmpty {
                            Button("Clean Up…") { confirmsCleanUp = true }
                                .disabled(isLocked)
                        }
                    }
                    if !trashable.isEmpty {
                        Text("A retry left these files in the meeting folder. Leftover audio can hold parts of the meeting that are not in the transcript.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if files.contains(where: { $0.kind == .subfolder }) {
                        Text("Roger does not write folders here and never moves them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files, id: \.url) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.kind == .subfolder ? "folder" : (file.kind.isAudio ? "waveform" : "doc.text"))
                                .foregroundStyle(.secondary)
                            Text(file.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Reveal in Finder")
                            if file.kind.isTrashable {
                                Button {
                                    trash([file.url])
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Move to Trash")
                                .disabled(isLocked || item.isUnfinished)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
```

Replace `.task(id: item) { refresh() }` with:

```swift
        .task(id: item) { refresh() }
        .onChange(of: reloadCount) { _, _ in refresh() }
```

Replace the confirmation dialog title and its button:

```swift
        .confirmationDialog(
            trashable.count == 1 ? "Move 1 extra file to the Trash?" : "Move \(trashable.count) extra files to the Trash?",
            isPresented: $confirmsCleanUp,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trash(trashable.map(\.url)) }
            Button("Cancel", role: .cancel) {}
```

Replace `trash(_:)`:

```swift
    /// Checks the meeting again, lists the folder again and moves only
    /// files that are still trashable extra files and that the user chose.
    /// Nothing moves when the meeting is now locked or unfinished; then the
    /// user is told why.
    private func trash(_ urls: [URL]) {
        guard mayTrash else {
            refresh()
            errorText = LibraryActions.extraFilesBusyMessage
            return
        }
        refresh()
        let current = Set(trashable.map { LibraryPath.canonical($0.url) })
        let allowed = urls.filter { current.contains(LibraryPath.canonical($0)) }
        let failed = LibraryActions.moveToTrash(allowed)
        refresh()
        errorText = LibraryActions.trashFailureMessage(failed)
    }
```

- [ ] **Step 7: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass. `MeetingExtraFilesTests.findsAndOrdersExtraFiles` and `audioSourcesGetNumberedIDs` are unchanged.

- [ ] **Step 8: Manual check**

Debug-run Roger with the sample library (`scripts/make-sample-library.sh`), open the meeting with extra files:
1. `mkdir "<session>/Slides"`: within about a second the section shows a `Slides` row with a folder icon and no Trash button, and Clean Up does not count it.
2. `touch "<session>/system.leftover 2.m4a"` while the entry is shown: the row appears without selecting another entry.
3. Start Clean Up, and before confirming copy a `mic-001.caf` into the session folder (the meeting is now unfinished): confirming shows "Roger did not move these files. ..." and every file is still there.
4. Record a meeting for a minute with the library window open and an entry in edit mode: the index now reports every chunk write in the session folder, so the list reloads about twice a second. The list must not flicker, the selection must stay and the edited text must not change.

- [ ] **Step 9: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/MeetingRecording/MeetingExtraFiles.swift Roger/Services/Library/LibraryActions.swift Roger/Services/Library/LibraryIndex.swift Roger/UI/Library/LibraryModel.swift Roger/UI/Library/LibraryExtraFilesSection.swift Roger/UI/Library/LibraryDetailView.swift Roger/RogerTests/MeetingExtraFilesTests.swift Roger/RogerTests/LibraryActionsTests.swift Roger/RogerTests/LibraryIndexTests.swift Roger/RogerTests/LibraryModelTests.swift
git commit -m "fix: show subfolders and fresh extra files of a meeting"
```

---

### Task 10: The list keeps scroll position and focus without a rebuild

`.id(model.results.isEmpty)` (commit b6c4d4a, "Rows added to the empty list kept the first row height, so only the title showed until the next layout") rebuilds the list when it goes from empty to filled, which loses the scroll position and the focus. Ruling 12: no fix is known that is certain without the rebuild. This task removes the rebuild and gives every row one fixed minimum height that is also the list's minimum row height, so a row the table sizes with its first-row height is still tall enough. It is verified by hand with the snapshot runner.

**Files:**
- Modify: `Roger/UI/Library/LibraryListView.swift`
- Modify: `Roger/App/LibrarySnapshotRunner.swift` (one more snapshot, DEBUG only)

**Interfaces:**
- Consumes: nothing new.
- Produces: `LibraryItemRow.height: CGFloat`.

- [ ] **Step 1: Add the refill snapshot**

In `Roger/App/LibrarySnapshotRunner.swift`, in step 7, right after `await waitUntil(seconds: 5) { model.appliedSearch.isEmpty }`:

```swift
        // 6b. The list filled again after the empty search: rows must show
        // all their lines (no rebuild of the list since 0.26.0).
        await settle()
        render(window, "06b-refilled.png", into: folder)
```

- [ ] **Step 2: See the current state**

Run:

```bash
cd /Users/jordi/git/roger/Roger
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | tail -3
APP="$(xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Roger.app"
LIB=$(mktemp -d)/library; SNAP=$(mktemp -d)
bash ../scripts/make-sample-library.sh "$LIB"
"$APP/Contents/MacOS/Roger" -RogerSnapshotDir "$SNAP" -libraryRoot "$LIB" -extraScanFolders '()'
open "$SNAP"
```

Expected: `01-all.png` and `06b-refilled.png` show full rows (the `.id` rebuild is still in place). Note the height of a three-line row (a transcript or meeting row) in `01-all.png`: pixels divided by 2 on a Retina screen.

- [ ] **Step 3: Remove the rebuild and give rows one height**

In `Roger/UI/Library/LibraryListView.swift`:

Replace the lines from `.listStyle(.inset)` through the end of the `.onChange(of: model.results.isEmpty)` block with:

```swift
        .listStyle(.inset)
        // No `.id` rebuild when the list fills (it lost the scroll position
        // and the focus). Rows added to an empty list may keep the table's
        // first row height, so every row has the same minimum height and
        // the table's minimum is that height too.
        .environment(\.defaultMinListRowHeight, LibraryItemRow.height)
        .focused($listFocused)
        .onChange(of: model.results.isEmpty) { _, isEmpty in
            // Give the list the focus once, on the first load, so the arrow
            // keys, Return and Cmd-Backspace work without a click.
            guard !isEmpty, !focusedOnce, model.appliedSearch.isEmpty else { return }
            focusedOnce = true
            DispatchQueue.main.async { listFocused = true }
        }
```

In `LibraryItemRow`, add:

```swift
    /// The height of a row with three lines (title, preview, details).
    /// Every row is at least this tall, so the list never cuts a row.
    static let height: CGFloat = 52
```

and replace `.padding(.vertical, 3)` at the end of `body` with:

```swift
        .padding(.vertical, 3)
        .frame(minHeight: Self.height, alignment: .center)
```

Set `height` to the value noted in Step 2 if it differs from 52 (round up to a whole point).

- [ ] **Step 4: Check by hand**

Build again and repeat the snapshot run from Step 2 into a new folder. Expected:
- `01-all.png` (rows added to the empty list at the first load) and `06b-refilled.png` (empty search, then filled): every transcript and meeting row shows title, preview and detail line; no row is cut. Log rows are as tall as the others, their two lines centered.
- In the running app (not snapshot mode): scroll the list down, choose a date filter with no entries, choose Any Date again: the list is filled, the scroll position is at the top of the new content and the list still has the focus (the arrow keys move the selection without a click).

If a row is cut in either snapshot, do not bring the `.id` back. Stop and report the two PNGs: the candidate failed and the issue stays open for 0.26.0 with this finding.

- [ ] **Step 5: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10`
Expected: all pass (no test covers the view).

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/UI/Library/LibraryListView.swift Roger/App/LibrarySnapshotRunner.swift
git commit -m "fix: keep the library list and its focus when it fills again"
```

---

### Task 11: Retry errors name leftovers, Finalise only for Roger meetings

A mic-track retry error names the system leftover file too (Ruling 14). "Finalise" is offered only for folders `LibraryActions.isRogerSessionFolder` accepts (Ruling 15) (#14).

**Files:**
- Modify: `Roger/Models/MeetingRecordingError.swift`
- Modify: `Roger/Services/Library/LibraryActions.swift` (new `finalisable`)
- Modify: `Roger/App/AppCoordinator.swift` (`refreshPendingMeetingSessions`)
- Test: `Roger/RogerTests/MeetingRecordingErrorTests.swift`, `Roger/RogerTests/LibraryActionsTests.swift`

**Interfaces:**
- Consumes: `LibraryActions.isRogerSessionFolder(_:layout:extraFolders:allowsSubfolders:)` (Task 9).
- Produces:
  - `MeetingRecordingError.trackAudioFailed(mic: Bool, system: Bool, setAside: [String])` (was two values).
  - `LibraryActions.finalisable(_ sessions: [MeetingSession], layout: LibraryLayout, extraFolders: [URL], dismissed: Set<String>) -> [MeetingSession]`.

- [ ] **Step 1: Write the failing tests**

In `Roger/RogerTests/MeetingRecordingErrorTests.swift`, `keptChunksAskForARetry`, change the pattern to the new case shape:

```swift
        guard case .trackAudioFailed(let mic, let system, _)? = error else {
```

and add to the struct:

```swift
    /// A mic track that needs a retry and a system leftover: both are said.
    @Test func aRetryErrorNamesTheLeftoverToo() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: true, systemNeedsRetry: false, setAside: ["system.leftover.m4a"])
        #expect(error?.errorDescription == "Microphone audio could not be fully saved, so the transcript may be incomplete. Roger kept the recording. Try again from the menu bar. Some audio is also saved as system.leftover.m4a in the meeting folder.")
    }

    @Test func aRetryErrorWithoutLeftoverStaysShort() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: false, systemNeedsRetry: true, setAside: [])
        #expect(error?.errorDescription == "System audio could not be fully saved, so the transcript may be incomplete. Roger kept the recording. Try again from the menu bar.")
    }
```

Add to `LibraryActionsTests` (it uses the file's `layout(_:)` and `touch(_:)` helpers):

```swift
    /// "Finalise" is offered only where Trash would treat the folder as a
    /// Roger meeting: a folder in an extra folder that merely holds a CAF
    /// file is not one.
    @Test func onlyRogerSessionFoldersAreFinalisable() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let library = layout(root.appendingPathComponent("Roger"))
        let extra = root.appendingPathComponent("Old Recordings", isDirectory: true)
        let roger = library.root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        let legacy = extra.appendingPathComponent("2025-01-02 10-00", isDirectory: true)
        let foreign = extra.appendingPathComponent("Podcast edits", isDirectory: true)
        let dismissed = library.root.appendingPathComponent("Meetings/2026/10/2026-10-14 09-00", isDirectory: true)
        for folder in [roger, legacy, foreign, dismissed] {
            try touch(folder.appendingPathComponent("mic-001.caf"))
        }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let sessions = [roger, legacy, foreign, dismissed].map { MeetingSession(id: UUID(), folder: $0, startedAt: date) }
        let offered = LibraryActions.finalisable(
            sessions, layout: library, extraFolders: [extra],
            dismissed: [dismissed.standardizedFileURL.path]
        )
        #expect(offered.map(\.folder) == [roger, legacy])
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/MeetingRecordingErrorTests -only-testing:RogerTests/LibraryActionsTests 2>&1 | tail -20`
Expected: build FAILS (the three-value pattern and `finalisable` do not exist).

- [ ] **Step 3: Name the leftovers**

In `Roger/Models/MeetingRecordingError.swift`, replace the case:

```swift
    /// The transcript was written, but a track's audio could not be saved.
    /// `setAside` names leftover files that also hold audio.
    case trackAudioFailed(mic: Bool, system: Bool, setAside: [String])
```

its message:

```swift
        case .trackAudioFailed(let mic, let system, let setAside):
            let tracks = mic && system ? "Microphone and system audio" : (mic ? "Microphone audio" : "System audio")
            let retry = "\(tracks) could not be fully saved, so the transcript may be incomplete. Roger kept the recording. Try again from the menu bar."
            guard !setAside.isEmpty else { return retry }
            return retry + " Some audio is also saved as \(Self.listed(setAside)) in the meeting folder."
```

and `afterFinalisation`:

```swift
    /// The error a finished finalisation reports, or nil. Kept chunks mean a
    /// retry can help ("Try again"); leftover files are named too. Audio that
    /// only sits in a leftover file needs no retry, so the message says where
    /// it is instead.
    static func afterFinalisation(micNeedsRetry: Bool, systemNeedsRetry: Bool, setAside: [String]) -> MeetingRecordingError? {
        if micNeedsRetry || systemNeedsRetry {
            return .trackAudioFailed(mic: micNeedsRetry, system: systemNeedsRetry, setAside: setAside)
        }
        if !setAside.isEmpty {
            return .audioSetAside(files: setAside)
        }
        return nil
    }
```

- [ ] **Step 4: Offer Finalise only for Roger meetings**

In `Roger/Services/Library/LibraryActions.swift`, add before `enum MediaOpening`:

```swift
    /// The unfinished sessions Roger offers to finalise: only folders that
    /// `isRogerSessionFolder` accepts (the check Trash uses) and that the
    /// user did not dismiss (`dismissed` holds standardized paths).
    static func finalisable(
        _ sessions: [MeetingSession],
        layout: LibraryLayout,
        extraFolders: [URL],
        dismissed: Set<String>
    ) -> [MeetingSession] {
        sessions.filter { session in
            !dismissed.contains(session.folder.standardizedFileURL.path)
                && isRogerSessionFolder(session.folder, layout: layout, extraFolders: extraFolders)
        }
    }
```

In `Roger/App/AppCoordinator.swift`, replace the body of `refreshPendingMeetingSessions()`:

```swift
    /// Also called by the library after it moved a meeting to the Trash, so
    /// the popover banner and the Unfinished list drop it right away. Only
    /// Roger's own session folders are offered (see `LibraryActions.finalisable`).
    func refreshPendingMeetingSessions() {
        pendingMeetingSessions = LibraryActions.finalisable(
            meetingRecorder.unfinalisedSessions(),
            layout: appState.libraryLayout,
            extraFolders: appState.extraScanFolders,
            dismissed: Set(appState.dismissedMeetingSessions)
        )
    }
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Models/MeetingRecordingError.swift Roger/Services/Library/LibraryActions.swift Roger/App/AppCoordinator.swift Roger/RogerTests/MeetingRecordingErrorTests.swift Roger/RogerTests/LibraryActionsTests.swift
git commit -m "fix: name leftover audio in retry errors and finalise only Roger meetings"
```

---

### Task 12: Editing a symlinked entry writes through the link

Editing or renaming an entry whose `.md` is a symlink writes the file the link points to; the link stays. The "changed on disk" check reads the target's date (Ruling 16) (#14).

**Files:**
- Modify: `Roger/Services/Library/LibraryDocument.swift` (`modificationDate(of:)`, `write(_:to:)`)
- Test: `Roger/RogerTests/LibraryDocumentTests.swift`

**Interfaces:**
- Consumes: `LibraryPath.canonical(_:)`, `LibraryPath.canonicalURL(_:isDirectory:)` (existing).
- Produces: no new names.

- [ ] **Step 1: Write the failing tests**

Add to `LibraryDocumentTests` (they use the file's `writeLog(in:)`, `read(_:)` and `date`):

```swift
    // MARK: Symlinks

    /// `<folder>/note.md` is a link to `<folder>/real/note.md`.
    private func linkedLog(in folder: URL) throws -> (link: URL, target: URL) {
        let real = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let target = try writeLog(in: real)
        let link = folder.appendingPathComponent("note.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return (link, target)
    }

    private func isLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    @Test func saveWritesThroughASymlink() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        let document = try LibraryDocument.load(link)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .saved)
        #expect(try isLink(link))
        #expect(try read(target) == document.frontmatter + "\nMine\n")
    }

    @Test func renameWritesThroughASymlink() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        try LibraryDocumentEditor.rename(fileAt: link, to: "Through the link")
        #expect(try isLink(link))
        #expect(try read(target).contains("title: \"Through the link\"\n"))
    }

    /// Another app edits the file the link points to: the save must notice.
    @Test func targetChangedBehindALinkIsDetected() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let (link, target) = try linkedLog(in: folder)
        let document = try LibraryDocument.load(link)
        let otherEdit = try read(target) + "Added by another app\n"
        try otherEdit.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(600)], ofItemAtPath: target.path)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .changedOnDisk)
        #expect(try read(target) == otherEdit)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryDocumentTests 2>&1 | tail -20`
Expected: FAIL in all three: `replaceItemAt` replaces the link with a plain file, and `attributesOfItem(atPath:)` reports the link's own date, so the other app's change is not seen (checked with Xcode 27).

- [ ] **Step 3: Follow the link**

In `Roger/Services/Library/LibraryDocument.swift`, replace `modificationDate(of:)`:

```swift
    /// Read without URL resource caching, so a change by another app is
    /// seen. For a symlink this is the date of the file it points to
    /// (`attributesOfItem` alone describes the link itself).
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: LibraryPath.canonical(url)))?[.modificationDate] as? Date
    }
```

and `write(_:to:)`:

```swift
    /// Writes into a scratch folder on the same volume and swaps the file
    /// in with `replaceItemAt`, which keeps the original's creation date,
    /// Finder tags and other attributes. The original is never truncated in
    /// place, so a failed write leaves it intact. A symlink is followed: the
    /// file it points to gets the text and the link stays a link.
    static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let target = LibraryPath.canonicalURL(url)
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(target.lastPathComponent)
        try Data(text.utf8).write(to: temp)
        _ = try fm.replaceItemAt(target, withItemAt: temp)
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryDocumentTests -only-testing:RogerTests/LibraryModelTests 2>&1 | tail -20`
Expected: all pass (`saveKeepsExtendedAttributes` and `saveKeepsTheCreationDate` too).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Library/LibraryDocument.swift Roger/RogerTests/LibraryDocumentTests.swift
git commit -m "fix: edit symlinked library entries through the link"
```

---

### Task 13: Relaunch asks about unsaved edits first

"Relaunch Roger" goes through the normal quit: the unsaved-edit question first, then a helper that waits until this process is gone and opens Roger again. The quit prompt and the relaunch helper never run at the same time (Ruling 13) (#14).

**Files:**
- Modify (replace whole file): `Roger/App/AppRelauncher.swift`
- Modify: `Roger/App/RogerApp.swift` (`applicationShouldTerminate`)
- Test: new `Roger/RogerTests/AppRelauncherTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `McpCommandFormatter.shellQuoted(_:)` (existing), `LibraryWindowController.confirmUnsavedEdit()` (existing).
- Produces:
  - `struct RelaunchGate { enum Decision { case quit, relaunch, stay }; private(set) var isPending: Bool; mutating func request(); mutating func decide(mayQuit: Bool) -> Decision }`.
  - `@MainActor enum AppRelauncher { static func relaunch(); static func terminateReply(mayQuit: Bool) -> NSApplication.TerminateReply; nonisolated static func helperScript(pid: Int32, bundlePath: String) -> String; nonisolated static func waitLoop(pid: Int32) -> String }`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/AppRelauncherTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct AppRelauncherTests {
    @Test func relaunchWaitsForTheQuitQuestion() {
        var gate = RelaunchGate()
        gate.request()
        #expect(gate.isPending)
        #expect(gate.decide(mayQuit: true) == .relaunch)
        #expect(!gate.isPending)
    }

    @Test func aCancelledQuitForgetsTheRelaunch() {
        var gate = RelaunchGate()
        gate.request()
        #expect(gate.decide(mayQuit: false) == .stay)
        // A later normal quit does not relaunch.
        #expect(gate.decide(mayQuit: true) == .quit)
    }

    @Test func aPlainQuitDoesNotRelaunch() {
        var gate = RelaunchGate()
        #expect(gate.decide(mayQuit: true) == .quit)
    }

    @Test func theHelperWaitsForThisProcessAndQuotesThePath() {
        #expect(AppRelauncher.helperScript(pid: 4242, bundlePath: "/Applications/Roger.app")
            == "while /bin/kill -0 4242 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open /Applications/Roger.app")
        #expect(AppRelauncher.helperScript(pid: 7, bundlePath: "/Users/x/My Apps/Rog'er.app")
            .hasSuffix("; /usr/bin/open '/Users/x/My Apps/Rog'\\''er.app'"))
    }

    /// The loop really waits: with a live pid the shell is still running
    /// after a moment, and it ends right after that process is gone.
    @Test func theWaitLoopEndsWhenTheProcessIsGone() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Only the wait loop: never run `open` in a test.
        waiter.arguments = ["-c", AppRelauncher.waitLoop(pid: sleeper.processIdentifier)]
        try waiter.run()
        try await Task.sleep(for: .milliseconds(400))
        #expect(waiter.isRunning)
        sleeper.terminate()
        sleeper.waitUntilExit()
        for _ in 0..<50 where waiter.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!waiter.isRunning)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/AppRelauncherTests 2>&1 | tail -20`
Expected: build FAILS (`RelaunchGate`, `helperScript`, `waitLoop` do not exist).

- [ ] **Step 3: Replace AppRelauncher**

Replace the whole content of `Roger/App/AppRelauncher.swift`:

```swift
import AppKit
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "AppRelauncher")

/// "Relaunch Roger" is a quit with a relaunch after it. The quit asks
/// about unsaved edits first; only when Roger may quit does the helper
/// start, so the question and the helper never run at the same time.
struct RelaunchGate: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        /// Quit, nothing else.
        case quit
        /// Start the helper, then quit.
        case relaunch
        /// The user cancelled (or the save failed): stay and forget the relaunch.
        case stay
    }

    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    /// After the unsaved-edit question. `mayQuit` is false for Cancel or a
    /// failed save.
    mutating func decide(mayQuit: Bool) -> Decision {
        defer { isPending = false }
        guard mayQuit else { return .stay }
        return isPending ? .relaunch : .quit
    }
}

/// Relaunches Roger. This is the reliable fix for a process-scoped CoreAudio
/// wedge (macOS 26.5.x can stop delivering input buffers to a long-lived
/// audio client; only a fresh process gets a fresh HAL connection). A helper
/// shell opens the bundle again once this process is gone.
@MainActor
enum AppRelauncher {
    private static var gate = RelaunchGate()

    /// Goes through the normal quit, so `applicationShouldTerminate` asks
    /// about unsaved edits first.
    static func relaunch() {
        gate.request()
        NSApp.terminate(nil)
    }

    /// The answer for `applicationShouldTerminate`, after the unsaved-edit
    /// question.
    static func terminateReply(mayQuit: Bool) -> NSApplication.TerminateReply {
        switch gate.decide(mayQuit: mayQuit) {
        case .stay:
            return .terminateCancel
        case .quit:
            return .terminateNow
        case .relaunch:
            // Without the helper a quit would just close Roger: stay instead.
            return startHelper() ? .terminateNow : .terminateCancel
        }
    }

    /// Waits until process `pid` is gone, then opens the app.
    nonisolated static func helperScript(pid: Int32, bundlePath: String) -> String {
        waitLoop(pid: pid) + "; /usr/bin/open " + McpCommandFormatter.shellQuoted(bundlePath)
    }

    /// Shell code that returns once process `pid` is gone.
    nonisolated static func waitLoop(pid: Int32) -> String {
        "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done"
    }

    private static func startHelper() -> Bool {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", helperScript(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)]
        do {
            try helper.run()
            return true
        } catch {
            logger.error("Relaunch helper did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
```

- [ ] **Step 4: One quit path**

In `Roger/App/RogerApp.swift`, replace `applicationShouldTerminate(_:)`:

```swift
    /// An unsaved edit in the library window is asked about first. A
    /// relaunch ("Relaunch Roger") starts its helper only after that.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let mayQuit = libraryWindowController?.confirmUnsavedEdit() ?? true
        return AppRelauncher.terminateReply(mayQuit: mayQuit)
    }
```

`AppCoordinator.relaunchApp()` keeps calling `AppRelauncher.relaunch()`.

- [ ] **Step 5: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/AppRelauncherTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 6: Manual check**

The "Relaunch Roger" button only shows after an audio wedge. For the check, change `if starved {` in `Roger/UI/MicrophoneSettingsView.swift` to `if true {` locally (do not commit it), Debug-run Roger, open the library, edit an entry without saving, then Settings > Microphone > "Relaunch Roger". Expected: the "Save changes to ...?" alert comes first. Cancel: Roger stays and does not restart later. Again, Don't Save: Roger quits and opens again once. Then `git checkout -- Roger/UI/MicrophoneSettingsView.swift`.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/App/AppRelauncher.swift Roger/App/RogerApp.swift Roger/RogerTests/AppRelauncherTests.swift Roger/Roger.xcodeproj
git commit -m "fix: ask about unsaved edits before Roger relaunches"
```

---

### Task 14: get_changes names its library, ack can check it

`get_changes` puts `library: <canonical root path>` in its TOON head; `ack` takes an optional `library` and refuses a different one (#15, Ruling 3). The tool catalog, the server instructions and the ingest skill follow.

**Files:**
- Modify: `Roger/RogerKit/ChangeQuery.swift` (`ChangeAnswer.render`)
- Modify: `Roger/RogerKit/RogerTools.swift` (`getChanges`, `ack`)
- Modify: `Roger/RogerMCP/ToolCatalog.swift`
- Modify: `skills/ingest-roger/SKILL.md`
- Test: `Roger/RogerKitTests/RogerToolsTests.swift`, `Roger/RogerTests/RogerMCPEndToEndTests.swift`, `Roger/RogerTests/BundledSkillTests.swift`

**Interfaces:**
- Consumes: `LibraryPath.canonical(_:)` (existing).
- Produces: `ChangeAnswer.render(library: String? = nil) -> String`; `ack` argument `library` (string, optional).

- [ ] **Step 1: Write the failing tests**

In `Roger/RogerKitTests/RogerToolsTests.swift`, `consumerLoopEndsEmpty`, the empty answer now ends with the library:

```swift
        #expect(again.text == "from: 4\nupTo: 3\nmore: false\ncount: 0\nlibrary: \(LibraryPath.canonical(root))")
```

Add to `RogerToolsTests`:

```swift
    @Test func getChangesNamesTheLibrary() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let text = tools(root).call("get_changes", arguments: ["consumer": .string("crystalline"), "summary": .bool(true)]).text
        #expect(text.hasPrefix("from: 1\nupTo: 3\nmore: false\ncount: 3\nlibrary: \(LibraryPath.canonical(root))\n\n==== roger entry"))
    }

    /// Roger switched to library B between get_changes and ack: the upTo of
    /// library A must not move B's bookmark.
    @Test func ackRefusesAnotherLibrary() async throws {
        let a = try await library()
        let b = try await library()
        defer {
            TempDir.remove(a)
            TempDir.remove(b)
        }
        let box = PreferencesBox(RogerPreferences(libraryRoot: a.path, extraScanFolders: []))
        let tools = RogerTools(
            locator: LibraryLocator(argument: nil, preferences: { box.get() }),
            registry: ExternalTranscriptRegistry(fileURL: a.appendingPathComponent("none.json"))
        )
        _ = tools.call("get_changes", arguments: ["consumer": .string("crystalline")])
        box.set(RogerPreferences(libraryRoot: b.path, extraScanFolders: []))
        let ack = tools.call("ack", arguments: [
            "consumer": .string("crystalline"), "upTo": .int(3), "library": .string(LibraryPath.canonical(a)),
        ])
        #expect(ack == .error("The library changed since get_changes. Call get_changes again."))
        #expect(try ConsumerBookmarks(root: b).bookmark("crystalline") == nil)
        #expect(!FileManager.default.fileExists(atPath: ConsumerBookmarks(root: b).folder.path))
    }

    /// `/var/...` and `/private/var/...` (and a trailing slash) are the same library.
    @Test func ackAcceptsAnotherSpellingOfTheSameLibrary() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        let canonical = LibraryPath.canonical(root)
        try #require(canonical.hasPrefix("/private/var/"))
        let spelling = String(canonical.dropFirst("/private".count)) + "/"
        let ack = tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(2), "library": .string(spelling)])
        #expect(ack.text == "Bookmark crystalline is now 2 (was 0).")
    }

    @Test func ackWithoutLibraryWorksAsBefore() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        #expect(tools(root).call("ack", arguments: ["consumer": .string("crystalline"), "upTo": .int(1)]).text == "Bookmark crystalline is now 1 (was 0).")
    }
```

In `Roger/RogerTests/RogerMCPEndToEndTests.swift`, `servesInitializeToolsListAndGetChanges`, after `#expect(text.contains("Called the supplier"))`:

```swift
        #expect(text.contains("\nlibrary: \(LibraryPath.canonical(root))\n"))
```

and inside the `for tool in tools` loop, after the `readOnly` check:

```swift
            if tool["name"] as? String == "ack" {
                let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
                #expect(properties?["library"] != nil)
            }
```

In `Roger/RogerTests/BundledSkillTests.swift`, `skillFollowsTheProtocolAndTheStyleRules`, add `"library"` to the `required` list:

```swift
        for required in ["get_changes", "summary: true", "ack", "library", "roger://", "$contains_any", "RESULT: ok more", "RESULT: failed:", "archived", "crystalline"] {
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/RogerToolsTests 2>&1 | tail -20`
Expected: FAIL in `consumerLoopEndsEmpty`, `getChangesNamesTheLibrary` and `ackRefusesAnotherLibrary` (the bookmark of B moves to 3).

- [ ] **Step 3: The head and the check**

In `Roger/RogerKit/ChangeQuery.swift`, replace `ChangeAnswer.render()`:

```swift
    /// TOON head (`from`, `upTo`, `more`, `count` and, when given,
    /// `library`), then the entries. `library` is the canonical root path;
    /// an agent hands it back to `ack`.
    public func render(library: String? = nil) -> String {
        var head = [
            TOON.field("from", .int(from)),
            TOON.field("upTo", .int(upTo)),
            TOON.field("more", .bool(more)),
            TOON.field("count", .int(entries.count)),
        ]
        if let library { head.append(TOON.field("library", .string(library))) }
        return ([head.joined(separator: "\n")] + entries.map { $0.render() }).joined(separator: "\n\n")
    }
```

In `Roger/RogerKit/RogerTools.swift`, last line of `getChanges`:

```swift
        return ChangeQuery.run(events: events, start: start, kinds: kinds, summary: summary, root: location.root)
            .render(library: LibraryPath.canonical(location.root))
```

and in `ack`, right after the `guard let consumer ... else { throw ToolFailure("ack needs consumer and upTo.") }`:

```swift
        // The library from get_changes: when Roger switched to another
        // library since, this upTo belongs to the old one.
        if let library = try args.string("library") {
            let given = URL(fileURLWithPath: (library as NSString).expandingTildeInPath, isDirectory: true)
            guard LibraryPath.canonical(given) == LibraryPath.canonical(location.root) else {
                throw ToolFailure("The library changed since get_changes. Call get_changes again.")
            }
        }
```

- [ ] **Step 4: Catalog, instructions and skill**

In `Roger/RogerMCP/ToolCatalog.swift`, in `instructions` replace the second and fifth lines:

```swift
    To ingest what is new, call get_changes with your consumer name, ingest each entry, then call ack with that consumer and the upTo and library from the answer. Repeat while more is true.
```

```swift
    A get_changes answer starts with from, upTo, more, count and library. Each entry then starts with the line ==== roger entry <seq> ====, lists its fields and has its Markdown after a blank line.
```

In the `get_changes` tool description replace `then call ack with the same consumer and the answer's upTo.` with `then call ack with the same consumer and the answer's upTo and library.`

Replace the `ack` tool:

```swift
        Tool(
            name: "ack",
            title: "Confirm ingested changes",
            description: "Moves a consumer's bookmark to upTo after you ingested everything up to it. Never moves it backwards: an older upTo leaves the bookmark as it is. upTo must not be after the last change. Pass the library from the get_changes answer: when Roger switched to another library since, ack refuses and changes nothing.",
            inputSchema: schema([
                "consumer": property("string", "Your consumer name."),
                "upTo": .object(["type": .string("integer"), "minimum": .int(0)]),
                "library": property("string", "The library value from the get_changes answer."),
            ], required: ["consumer", "upTo"]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
```

In `skills/ingest-roger/SKILL.md`, "The loop":

Step 1:

```markdown
1. Call `get_changes(consumer: "crystalline", summary: true)`. Note `from`, `upTo`, `more`, `library` and the entries (key, event, kind, title, date).
```

Step 5:

```markdown
5. Only when every group of the range succeeded, call `ack(consumer: "crystalline", upTo: <upTo from step 1>, library: <library from step 1>)`. Never ack the `upTo` of a call with `kinds`. If `ack` answers that the library changed, Roger now uses another library: start again at step 1 (this counts as a round).
```

- [ ] **Step 5: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass (the scheme builds `roger-mcp` and runs `RogerMCPEndToEndTests` and `BundledSkillTests`). `ChangeQueryTests` are unchanged: they call `render()` without a library.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/RogerKit/ChangeQuery.swift Roger/RogerKit/RogerTools.swift Roger/RogerMCP/ToolCatalog.swift skills/ingest-roger/SKILL.md Roger/RogerKitTests/RogerToolsTests.swift Roger/RogerTests/RogerMCPEndToEndTests.swift Roger/RogerTests/BundledSkillTests.swift
git commit -m "fix: refuse an ack for a library Roger no longer uses"
```

(The bundled skill changes, so installed skills show "Outdated" until updated in Settings > Agents. That is intended.)

---

### Task 15: Unexpected tool errors name the tool and the library; status reports an unreadable log

Finding 4: an unexpected error names the tool and the library, and `status` reports a change log it cannot read instead of "ready, 0 events" (Ruling 24).

**Files:**
- Modify: `Roger/RogerKit/RogerTools.swift` (`call`, `status`)
- Test: `Roger/RogerKitTests/RogerToolsTests.swift`

**Interfaces:**
- Consumes: `ItemKeyError`, `ConsumerBookmarkError` (existing).
- Produces: no new names.

- [ ] **Step 1: Write the failing tests**

Add to `RogerToolsTests`:

```swift
    /// `changes.jsonl` that opens but cannot be read (here: a folder).
    private func unreadableLog() async throws -> URL {
        let root = try TempDir.make()
        let log = ChangeLogFile.url(root: root)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        return root
    }

    @Test func statusReportsAnUnreadableChangeLog() async throws {
        let root = try await unreadableLog()
        defer { TempDir.remove(root) }
        let status = tools(root).call("status", arguments: [:])
        #expect(!status.isError)
        #expect(status.text.contains("state: not readable"))
        #expect(status.text.contains("message: \"Roger cannot read the change log at \(ChangeLogFile.url(root: root).path): "))
        #expect(!status.text.contains("lastSeq"))
    }

    @Test func anUnexpectedErrorNamesTheToolAndTheLibrary() async throws {
        let root = try await unreadableLog()
        defer { TempDir.remove(root) }
        let output = tools(root).call("get_changes", arguments: ["consumer": .string("crystalline")])
        #expect(output.isError)
        #expect(output.text.hasPrefix("get_changes failed in the library at \(root.path): "))
    }

    @Test func expectedErrorsKeepTheirOwnText() async throws {
        let root = try await library()
        defer { TempDir.remove(root) }
        #expect(tools(root).call("get_item", arguments: ["key": .string("Logs/2026/01/none")]).text == "No item with the key \"Logs/2026/01/none\".")
        #expect(tools(root).call("ack", arguments: ["consumer": .string("A"), "upTo": .int(1)]).text.hasPrefix("\"A\" is not a valid consumer name."))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/RogerToolsTests 2>&1 | tail -20`
Expected: FAIL in `statusReportsAnUnreadableChangeLog` (it says `state: ready`, `lastSeq: 0`) and `anUnexpectedErrorNamesTheToolAndTheLibrary` (only the bare Cocoa message).

- [ ] **Step 3: Implement**

In `Roger/RogerKit/RogerTools.swift`, `call(_:arguments:)`, replace the catch clauses:

```swift
        } catch let failure as ToolFailure {
            return .error(failure.message)
        } catch let keyError as ItemKeyError {
            return .error(keyError.localizedDescription)
        } catch let nameError as ConsumerBookmarkError {
            return .error(nameError.localizedDescription)
        } catch {
            // Anything else is unexpected (a file system error): say which
            // tool and which library, so the agent can tell the user.
            return .error("\(name) failed in the library at \(location.root.path): \(error.localizedDescription)")
        }
```

In `status(_:)`, replace `let events = (try? ChangeLogFile.readEvents(root: location.root)) ?? []`:

```swift
        let events: [ChangeEvent]
        do {
            events = try ChangeLogFile.readEvents(root: location.root)
        } catch {
            // Not "ready, 0 events": the agent must know the log is unreadable.
            let path = ChangeLogFile.url(root: location.root).path
            lines.append(TOON.field("state", .string("not readable")))
            lines.append(TOON.field("message", .string("Roger cannot read the change log at \(path): \(error.localizedDescription)")))
            return lines.joined(separator: "\n")
        }
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' 2>&1 | tail -10`
Expected: all pass (`getItemRejectsPaths`, `ackRules` and `deniedAccessExplainsFilesAndFolders` keep their texts).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/RogerKit/RogerTools.swift Roger/RogerKitTests/RogerToolsTests.swift
git commit -m "fix: name the tool and the library in unexpected roger-mcp errors"
```

---

### Task 16: fsync the change log and the bookmarks

Finding 1: `fsync` after each change log append, and on the bookmark temp file before the rename (Ruling 21).

**Files:**
- Modify: `Roger/RogerKit/FileLock.swift` (new `FileIO`)
- Modify: `Roger/RogerKit/ChangeLog.swift` (`locked`; the private `writeAll` moves to `FileIO`)
- Modify: `Roger/RogerKit/ConsumerBookmarks.swift` (`write`)
- Test: new `Roger/RogerKitTests/FileIOTests.swift`, `Roger/RogerKitTests/ConsumerBookmarksTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `POSIXError.current` (existing, `FileLock.swift`).
- Produces: `enum FileIO { static func writeAll(_ fd: Int32, _ data: Data) throws; static func sync(_ fd: Int32) throws }` (internal to RogerKit, `@testable` in tests).

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerKitTests/FileIOTests.swift`:

```swift
import Foundation
import Testing
@testable import RogerKit

struct FileIOTests {
    @Test func writeAllAndSyncPutTheBytesOnDisk() throws {
        let folder = try TempDir.make()
        defer { TempDir.remove(folder) }
        let url = folder.appendingPathComponent("data")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
        try #require(fd >= 0)
        defer { close(fd) }
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        try FileIO.writeAll(fd, data)
        try FileIO.sync(fd)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func syncReportsAnError() {
        #expect(throws: POSIXError.self) { try FileIO.sync(-1) }
    }
}
```

Add to `ConsumerBookmarksTests`:

```swift
    /// The temp file cannot be written: the old bookmark stays, no temp file is left.
    @Test func aFailedWriteKeepsTheOldBookmark() throws {
        let root = try TempDir.make()
        let bookmarks = ConsumerBookmarks(root: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bookmarks.folder.path)
            TempDir.remove(root)
        }
        try bookmarks.ack("crystalline", upTo: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bookmarks.folder.path)
        #expect(throws: (any Error).self) { try bookmarks.ack("crystalline", upTo: 5) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bookmarks.folder.path)
        #expect(try bookmarks.bookmark("crystalline")?.seq == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bookmarks.folder.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/FileIOTests -only-testing:RogerKitTests/ConsumerBookmarksTests 2>&1 | tail -20`
Expected: build FAILS (`FileIO` does not exist). `aFailedWriteKeepsTheOldBookmark` guards the new write path; it passes with the old one too.

- [ ] **Step 3: FileIO**

In `Roger/RogerKit/FileLock.swift`, add before `enum FileLock`:

```swift
/// Writes to a descriptor, shared by the change log and the bookmarks.
enum FileIO {
    /// Loops only if the kernel takes fewer bytes.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, base + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current
                }
                offset += count
            }
        }
    }

    /// `fsync`: the bytes are on the disk before the caller goes on.
    static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            guard errno == EINTR else { throw POSIXError.current }
        }
    }
}
```

- [ ] **Step 4: Use it**

In `Roger/RogerKit/ChangeLog.swift`, delete the private static `writeAll(_:_:)` and in `locked(_:)` replace `try Self.writeAll(fd, Data(text.utf8))` with:

```swift
            try FileIO.writeAll(fd, Data(text.utf8))
            // On disk before a writer or a reader relies on the new seq.
            try FileIO.sync(fd)
```

In `Roger/RogerKit/ConsumerBookmarks.swift`, replace the start of `write(_:name:)` up to the `guard rename(...)` line:

```swift
    /// The temp file is `fsync`ed before the `rename`, so a crash never
    /// leaves an empty bookmark in place of a good one.
    private func write(_ bookmark: ConsumerBookmark, name: String) throws {
        let text = "{\"seq\":\(bookmark.seq),\"updatedAt\":\"\(RFC3339.string(bookmark.updatedAt))\"}\n"
        let temp = folder.appendingPathComponent(".\(name).json.\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError.current }
        do {
            try FileIO.writeAll(fd, Data(text.utf8))
            try FileIO.sync(fd)
            close(fd)
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, fileURL(name).path) == 0 else {
```

(the rest of the function stays).

- [ ] **Step 5: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' 2>&1 | tail -10`
Expected: all pass (`twoHandlesNeverShareASeq`, `concurrentAcksEndAtTheHighest` and `fileHasTheSpecShapeAndNoTempFilesRemain` too).

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/RogerKit/FileLock.swift Roger/RogerKit/ChangeLog.swift Roger/RogerKit/ConsumerBookmarks.swift Roger/RogerKitTests/FileIOTests.swift Roger/RogerKitTests/ConsumerBookmarksTests.swift Roger/Roger.xcodeproj
git commit -m "fix: sync change log and bookmark writes to disk"
```

---

### Task 17: One decoder and cached date formatters in the change log parse

Finding 2: `ChangeEvent.parse` builds a `JSONDecoder` and `RFC3339.date` two `ISO8601DateFormatter`s per line. Make them once.

**Files:**
- Modify: `Roger/RogerKit/RFC3339.swift` (`date`)
- Modify: `Roger/RogerKit/ChangeEvent.swift` (`parse`)
- Test: `Roger/RogerKitTests/ChangeLogTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no new names.

- [ ] **Step 1: Write the test**

Add to `ChangeLogTests`:

```swift
    /// The parse uses one decoder and two date formatters for every line.
    /// Several readers at once (roger-mcp answers tool calls in parallel)
    /// must all get every event.
    @Test func parsingIsSafeFromSeveralTasks() async throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let lines = (1...2_000).map { seq in
            ChangeEvent(seq: seq, at: at, event: .created, kind: .log, key: "Logs/2026/10/\(seq)", path: "Logs/2026/10/\(seq).md").jsonLine()
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { ChangeLogFile.parse(data).count } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(counts == Array(repeating: 2_000, count: 8))
        #expect(RFC3339.date("2026-10-13T14:32:41.250+02:00") != nil)
    }
```

- [ ] **Step 2: Run it**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' -only-testing:RogerKitTests/ChangeLogTests 2>&1 | tail -10`
Expected: PASS already. It guards the change: shared formatters and a shared decoder must stay correct when several tasks parse at once.

- [ ] **Step 3: Make them once**

In `Roger/RogerKit/RFC3339.swift`, replace `date(_:)`:

```swift
    /// Accepts any offset or `Z`, with or without fractional seconds.
    public static func date(_ text: String) -> Date? {
        plain.date(from: text) ?? fractional.date(from: text)
    }

    // Made once: the change log parses one date per event. Formatters are
    // thread-safe on macOS, and these two are never changed after they are
    // made; `ISO8601DateFormatter` is not marked `Sendable`, hence the
    // `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
```

(`string(_:timeZone:)` keeps building its formatter: it takes a time zone and runs once per write.)

In `Roger/RogerKit/ChangeEvent.swift`, before `parse(_:)`:

```swift
    /// Made once: `parse` runs for every line of the log.
    private static let decoder = JSONDecoder()
```

and in `parse(_:)` use `try? decoder.decode(Raw.self, from: line)`. (`JSONDecoder` is `Sendable` in the macOS 27 SDK; a `static let` of `ISO8601DateFormatter` is a Swift 6 error without `nonisolated(unsafe)`, checked with Xcode 27.)

- [ ] **Step 4: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme RogerKitTests -destination 'platform=macOS' 2>&1 | tail -10`
Expected: all pass, no new warnings.

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/RogerKit/RFC3339.swift Roger/RogerKit/ChangeEvent.swift Roger/RogerKitTests/ChangeLogTests.swift
git commit -m "perf: parse the change log with one decoder and shared formatters"
```

---

### Task 18: LogEntrySaver (saving a log entry after dictation)

#10: the decisions of saving a log entry (empty text, preset language, keep audio and `sources`, recording only after a successful write) move out of `AppCoordinator` into a plain type that tests drive with a temp folder and a fake encoder (Ruling 17).

**Files:**
- Create: `Roger/Services/LogEntrySaver.swift`
- Modify: `Roger/App/AppCoordinator.swift` (`saveLogEntry`, its two calls in `runPipeline`)
- Test: new `Roger/RogerTests/LogEntrySaverTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LogEntryWriter.write(_:layout:audioSamples:encodeAudio:)`, `LogAudioEncoder.writeM4A`, `DictationPreset` (existing).
- Produces: `struct LogEntrySaver { enum Outcome: Equatable { case empty, saved(URL), failed(String) }; let layout: LibraryLayout; var encodeAudio: @Sendable ([Float], URL) throws -> Void; static func isEmpty(_ text: String) -> Bool; @MainActor func save(_ text: String, preset: DictationPreset, startedAt: Date, endedAt: Date, detectedLanguage: String?, samples: [Float]?, recordWritten: @MainActor (URL) -> Void) async -> Outcome }`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/LogEntrySaverTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

@MainActor
struct LogEntrySaverTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// Writes four bytes instead of encoding, so tests need no audio stack.
    private static let fakeEncoder: @Sendable ([Float], URL) throws -> Void = { _, url in
        try Data("m4a!".utf8).write(to: url)
    }

    private func preset(keepAudio: Bool, language: String? = nil) -> DictationPreset {
        var preset = DictationPreset.log
        preset.keepAudio = keepAudio
        preset.language = language
        return preset
    }

    private func save(
        _ text: String,
        root: URL,
        preset: DictationPreset,
        detected: String? = nil,
        samples: [Float]? = [0.1, 0.2],
        recorded: inout [URL]
    ) async -> LogEntrySaver.Outcome {
        var urls: [URL] = []
        let saver = LogEntrySaver(layout: LibraryLayout(root: root), encodeAudio: Self.fakeEncoder)
        let outcome = await saver.save(
            text, preset: preset, startedAt: start, endedAt: start.addingTimeInterval(12),
            detectedLanguage: detected, samples: samples, recordWritten: { urls.append($0) }
        )
        recorded += urls
        return outcome
    }

    @Test func keepAudioWritesTheRecordingAndListsIt() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        let outcome = await save("Called the supplier", root: root, preset: preset(keepAudio: true), recorded: &recorded)
        guard case .saved(let url) = outcome else {
            Issue.record("expected saved, got \(outcome)")
            return
        }
        #expect(recorded == [url])
        let audio = url.deletingPathExtension().appendingPathExtension("m4a")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("sources:\n  - { id: audio, resource: \"\(audio.lastPathComponent)\" }\n"))
    }

    @Test func withoutKeepAudioNoRecordingIsKept() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        let outcome = await save("Called the supplier", root: root, preset: preset(keepAudio: false), recorded: &recorded)
        guard case .saved(let url) = outcome else {
            Issue.record("expected saved, got \(outcome)")
            return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == [url.lastPathComponent])
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("sources:"))
    }

    @Test func emptyTextWritesAndRecordsNothing() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        #expect(await save("  \n", root: root, preset: preset(keepAudio: true), recorded: &recorded) == .empty)
        #expect(recorded.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func aFailedWriteRecordsNothing() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let notAFolder = base.appendingPathComponent("file")
        try Data("x".utf8).write(to: notAFolder)
        var recorded: [URL] = []
        let outcome = await save("Called the supplier", root: notAFolder, preset: preset(keepAudio: false), recorded: &recorded)
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(recorded.isEmpty)
    }

    @Test func theDetectedLanguageWinsOverThePresetPin() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        var recorded: [URL] = []
        guard case .saved(let pinned) = await save("Hallo", root: root, preset: preset(keepAudio: false, language: "de"), recorded: &recorded),
              case .saved(let detected) = await save("Hello", root: root, preset: preset(keepAudio: false, language: "de"), detected: "en", recorded: &recorded)
        else {
            Issue.record("expected two saved entries")
            return
        }
        #expect(try String(contentsOf: pinned, encoding: .utf8).contains("language: \"de\"\n"))
        #expect(try String(contentsOf: detected, encoding: .utf8).contains("language: \"en\"\n"))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LogEntrySaverTests 2>&1 | tail -20`
Expected: build FAILS ("cannot find 'LogEntrySaver' in scope").

- [ ] **Step 3: Write LogEntrySaver**

Create `Roger/Services/LogEntrySaver.swift`:

```swift
import Foundation

/// Saving a log entry after a dictation with a log preset: what is written
/// (text, audio, `sources`) and what is recorded for agents. The
/// coordinator only shows the outcome.
struct LogEntrySaver: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Nothing left after processing. Nothing was written.
        case empty
        /// The entry is on disk and recorded.
        case saved(URL)
        /// The write failed. Nothing was recorded.
        case failed(String)
    }

    let layout: LibraryLayout
    var encodeAudio: @Sendable ([Float], URL) throws -> Void = LogAudioEncoder.writeM4A

    /// True when there is nothing to save.
    static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the entry: the language is the detected one, else the
    /// preset's pin; the recording is kept only when the preset says so
    /// (then `sources` lists it). `recordWritten` runs only after the
    /// file is on disk.
    @MainActor
    func save(
        _ text: String,
        preset: DictationPreset,
        startedAt: Date,
        endedAt: Date,
        detectedLanguage: String?,
        samples: [Float]?,
        recordWritten: @MainActor (URL) -> Void
    ) async -> Outcome {
        guard !Self.isEmpty(text) else { return .empty }
        let entry = LogEntry(
            text: text,
            startedAt: startedAt,
            endedAt: endedAt,
            presetName: preset.name,
            language: detectedLanguage ?? preset.language
        )
        do {
            let url = try await LogEntryWriter.write(
                entry,
                layout: layout,
                audioSamples: preset.keepAudio ? samples : nil,
                encodeAudio: encodeAudio
            )
            recordWritten(url)
            return .saved(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: The coordinator uses it**

In `Roger/App/AppCoordinator.swift`, replace `saveLogEntry(...)` from its doc comment down to (not including) `audioLevelMeter.reset()` that follows the `do/catch` (the success part with the "Logged" indicator stays):

```swift
    /// Writes a log entry instead of typing (`LogEntrySaver`). On failure
    /// the text stays in `lastTranscription` so nothing is lost.
    private func saveLogEntry(
        _ text: String,
        preset: DictationPreset,
        startedAt: Date,
        endedAt: Date,
        detectedLanguage: String?,
        samples: [Float]?
    ) async {
        if LogEntrySaver.isEmpty(text) {
            logger.info("Log entry skipped: empty text after processing")
            appState.lastLogEntryURL = nil
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .error("No speech detected - try speaking louder or closer to the mic")
            return
        }
        appState.lastTranscription = text
        let layout = appState.libraryLayout
        let outcome = await LogEntrySaver(layout: layout).save(
            text, preset: preset, startedAt: startedAt, endedAt: endedAt,
            detectedLanguage: detectedLanguage, samples: samples
        ) { [libraryChanges] url in
            libraryChanges.recordWritten(markdownURL: url, kind: .log)
        }
        switch outcome {
        case .saved(let url):
            appState.lastLogEntryURL = url
            logger.notice("Log entry saved: \(url.path, privacy: .public)")
        case .failed(let message):
            logger.error("Log entry write failed: \(message, privacy: .public)")
            appState.lastLogEntryURL = nil
            floatingPanel.hide()
            audioLevelMeter.reset()
            appState.dictationState = .error("Could not save the log entry. Copy the text from the menu bar.")
            return
        case .empty:
            return
        }

```

In `runPipeline`, both calls of `saveLogEntry` pass the detected language only (the saver falls back to the preset's pin). Replace in each call

```swift
                                               language: result.detectedLanguage ?? activePreset.language, samples: samples)
```

with

```swift
                                               detectedLanguage: result.detectedLanguage, samples: samples)
```

(and the same with the other indentation in the second call).

- [ ] **Step 5: Run the tests and build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/Services/LogEntrySaver.swift Roger/App/AppCoordinator.swift Roger/RogerTests/LogEntrySaverTests.swift Roger/Roger.xcodeproj
git commit -m "refactor: move saving a log entry into a tested type"
```

---

### Task 19: LibraryMigrationRun (the first-launch migration)

#10: the decisions of the one-time migration (when to ask, what moves, which folders become extra scan folders) move into a plain type. `AppCoordinator` keeps the guards, the alert and writing the settings.

**Files:**
- Create: `Roger/Services/LibraryMigrationRun.swift`
- Modify: `Roger/App/AppCoordinator.swift` (`runLibraryMigrationIfNeeded`)
- Test: new `Roger/RogerTests/LibraryMigrationRunTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryMigration.isInsideLibrary/plan/execute`, `MeetingSessionScanner.sessionFolders(in:maxDepth:)` (existing).
- Produces: `struct LibraryMigrationRun { struct Input { layout, extraFolders, legacyTranscriptFolder: URL?, legacyMeetingsFolder: URL }; struct Result: Equatable { extraFolders: [URL]; moved: [URL]; failedCount: Int; asked: Bool }; @MainActor static func run(_ input: Input, ask: (Int, URL) -> Bool) -> Result }`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/LibraryMigrationRunTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

@MainActor
struct LibraryMigrationRunTests {
    /// `<base>/Roger Recordings/<name>` with a `mic.m4a`.
    @discardableResult
    private func oldSession(_ base: URL, _ name: String = "2026-01-02 10-00") throws -> URL {
        let folder = base.appendingPathComponent("Roger Recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: folder.appendingPathComponent("mic.m4a"))
        return folder
    }

    private func input(_ base: URL, extras: [URL] = [], transcripts: URL? = nil, old: URL? = nil) -> LibraryMigrationRun.Input {
        LibraryMigrationRun.Input(
            layout: LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true)),
            extraFolders: extras,
            legacyTranscriptFolder: transcripts,
            legacyMeetingsFolder: old ?? base.appendingPathComponent("Roger Recordings", isDirectory: true)
        )
    }

    @Test func moveBringsTheSessionsIntoTheLibrary() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        try oldSession(base)
        var questions: [Int] = []
        let result = LibraryMigrationRun.run(input(base)) { count, _ in
            questions.append(count)
            return true
        }
        #expect(questions == [1])
        #expect(result.asked)
        #expect(result.extraFolders.isEmpty)
        #expect(result.failedCount == 0)
        #expect(result.moved.map(\.lastPathComponent) == ["2026-01-02 10-00"])
        let moved = base.appendingPathComponent("Roger/Meetings/2026/01/2026-01-02 10-00/mic.m4a")
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func keepInPlaceMakesTheOldFolderAnExtraFolder() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try oldSession(base)
        let result = LibraryMigrationRun.run(input(base)) { _, _ in false }
        #expect(result.extraFolders == [base.appendingPathComponent("Roger Recordings", isDirectory: true)])
        #expect(result.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: session.path))
    }

    @Test func noSessionsMeansNoQuestion() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Roger Recordings"), withIntermediateDirectories: true)
        let result = LibraryMigrationRun.run(input(base)) { _, _ in
            Issue.record("asked without sessions")
            return true
        }
        #expect(!result.asked)
        #expect(result.extraFolders.isEmpty)
    }

    @Test func anOldFolderInsideTheLibraryIsLeftAlone() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let meetings = base.appendingPathComponent("Roger/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings.appendingPathComponent("2026-01-02 10-00"), withIntermediateDirectories: true)
        try Data().write(to: meetings.appendingPathComponent("2026-01-02 10-00/mic.m4a"))
        let result = LibraryMigrationRun.run(input(base, old: meetings)) { _, _ in
            Issue.record("asked for a folder inside the library")
            return true
        }
        #expect(!result.asked)
    }

    @Test func theTranscriptFolderIsAddedOnce() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let transcripts = base.appendingPathComponent("My Transcripts", isDirectory: true)
        let result = LibraryMigrationRun.run(input(base, extras: [transcripts], transcripts: transcripts)) { _, _ in true }
        #expect(result.extraFolders == [transcripts])
    }

    @Test func aFailedMoveKeepsTheOldFolderAsAnExtraFolder() throws {
        let base = try TempFolder.make()
        let root = base.appendingPathComponent("Roger", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            TempFolder.remove(base)
        }
        let session = try oldSession(base)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let result = LibraryMigrationRun.run(input(base)) { _, _ in true }
        #expect(result.failedCount == 1)
        #expect(result.extraFolders == [base.appendingPathComponent("Roger Recordings", isDirectory: true)])
        #expect(FileManager.default.fileExists(atPath: session.path))
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryMigrationRunTests 2>&1 | tail -20`
Expected: build FAILS ("cannot find 'LibraryMigrationRun' in scope").

- [ ] **Step 3: Write LibraryMigrationRun**

Create `Roger/Services/LibraryMigrationRun.swift`:

```swift
import Foundation

/// The first-launch move of pre-library meetings into the library, without
/// the alert: `ask` is the "Move your meetings?" question. Folders that
/// stay in place become extra scan folders, so their meetings are still
/// found.
struct LibraryMigrationRun {
    struct Input {
        let layout: LibraryLayout
        let extraFolders: [URL]
        /// The custom file transcript folder of older versions, if any.
        let legacyTranscriptFolder: URL?
        /// The custom meetings folder of older versions, else `~/Documents/Roger Recordings/`.
        let legacyMeetingsFolder: URL
    }

    struct Result: Equatable {
        /// The extra scan folders afterwards.
        var extraFolders: [URL]
        /// Session folders that now live in the library.
        var moved: [URL] = []
        /// Sessions that could not be moved (they stay in place).
        var failedCount = 0
        /// True when `ask` was called.
        var asked = false
    }

    /// `ask(sessionCount, folder)` returns true for Move. It is called only
    /// when the old folder has sessions and lies outside the library.
    @MainActor
    static func run(_ input: Input, ask: (Int, URL) -> Bool) -> Result {
        var extras = input.extraFolders
        func addExtra(_ url: URL) {
            if !extras.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                extras.append(url)
            }
        }
        if let transcripts = input.legacyTranscriptFolder {
            addExtra(transcripts)
        }
        var result = Result(extraFolders: [])
        let old = input.legacyMeetingsFolder
        let sessions = MeetingSessionScanner.sessionFolders(in: old, maxDepth: 1)
        if !sessions.isEmpty, !LibraryMigration.isInsideLibrary(old, layout: input.layout) {
            result.asked = true
            if ask(sessions.count, old) {
                let outcome = LibraryMigration.execute(LibraryMigration.plan(sessionFolders: sessions, layout: input.layout))
                result.moved = outcome.moved
                result.failedCount = outcome.failed.count
                if !outcome.failed.isEmpty { addExtra(old) }
            } else {
                addExtra(old)
            }
        }
        result.extraFolders = extras
        return result
    }
}
```

- [ ] **Step 4: The coordinator uses it**

In `Roger/App/AppCoordinator.swift`, replace the body of `runLibraryMigrationIfNeeded()` (keep its doc comment):

```swift
    func runLibraryMigrationIfNeeded() {
        guard !appState.libraryMigrationDone, !meetingRecorder.isActive else { return }
        defer {
            appState.libraryMigrationDone = true
            refreshPendingMeetingSessions()
        }
        let layout = appState.libraryLayout
        let input = LibraryMigrationRun.Input(
            layout: layout,
            extraFolders: appState.extraScanFolders,
            legacyTranscriptFolder: appState.legacyFileTranscriptFolder,
            legacyMeetingsFolder: appState.legacyMeetingRecordingsFolder ?? LibraryLayout.legacyRecordingsFolder
        )
        let result = LibraryMigrationRun.run(input) { count, folder in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Move your meetings to the Roger library?"
            alert.informativeText = "Roger now keeps log entries, meetings and transcripts in one folder: \(layout.root.path). Move \(count) \(count == 1 ? "meeting" : "meetings") from \(folder.path) there? If you keep them in place, Roger still finds them."
            alert.addButton(withTitle: "Move")
            alert.addButton(withTitle: "Keep in Place")
            return alert.runModal() == .alertFirstButtonReturn
        }
        if !result.moved.isEmpty || result.failedCount > 0 {
            logger.notice("Library migration moved \(result.moved.count) meetings, \(result.failedCount) failed")
        }
        appState.extraScanFolders = result.extraFolders
    }
```

- [ ] **Step 5: Run the tests and build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass (`LibraryMigrationTests` unchanged).

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/Services/LibraryMigrationRun.swift Roger/App/AppCoordinator.swift Roger/RogerTests/LibraryMigrationRunTests.swift Roger/Roger.xcodeproj
git commit -m "refactor: move the first-launch migration into a tested type"
```

---

### Task 20: MeetingFinalisationSteps (the file steps of a finalisation)

#10: after transcription, `runFinalisationPipeline` writes segments, writes `transcript.md`, records the change, deletes the archives when audio is not kept and picks the error. These steps move into a plain `@MainActor` type with tests; the service keeps capture, encoding, transcription and its state.

**Files:**
- Create: `Roger/Services/MeetingRecording/MeetingFinalisationSteps.swift`
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (`runFinalisationPipeline`)
- Test: new `Roger/RogerTests/MeetingFinalisationStepsTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `MeetingTranscriptWriter.write`, `MeetingSegmentWriter.write/removeIfExists`, `MeetingCheckpointStore.chunks`, `MeetingRecordingError.afterFinalisation` (Task 11).
- Produces: `@MainActor enum MeetingFinalisationSteps { struct Track: Equatable, Sendable { var needsRetry: Bool; var leftover: URL?; var archiveExisted: Bool; var audioFailed: Bool }; struct Input { session, paragraphs, metadata, markers, segmentStart, durationSeconds, mic, system, sleepInterrupted }; enum Outcome { case finished(transcript: URL, error: MeetingRecordingError?), failed(String) }; static func keepsAudio(setting: Bool, mic: Track, system: Track) -> Bool; static func run(_ input: Input, recordWritten: (URL) -> Void) -> Outcome }`.

- [ ] **Step 1: Write the failing tests**

Create `Roger/RogerTests/MeetingFinalisationStepsTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

@MainActor
struct MeetingFinalisationStepsTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ base: URL) throws -> MeetingSession {
        let folder = base.appendingPathComponent("2026-09-21 16-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MeetingSession(id: UUID(), folder: folder, startedAt: start)
    }

    private func input(
        _ session: MeetingSession,
        paragraphs: [MeetingTranscriptMerger.Paragraph] = [.init(speaker: "Me", startTime: 5, text: "Hello"), .init(speaker: "Other 1", startTime: 40, text: "Hi")],
        audioKept: Bool = true,
        markers: [MeetingCheckpointMarker] = [],
        mic: MeetingFinalisationSteps.Track = .init(),
        system: MeetingFinalisationSteps.Track = .init(),
        sleepInterrupted: Bool = false
    ) -> MeetingFinalisationSteps.Input {
        MeetingFinalisationSteps.Input(
            session: session,
            paragraphs: paragraphs,
            metadata: MeetingTranscriptWriter.Metadata(
                session: session, durationSeconds: 60, speakerCount: 2, language: "en",
                micPresent: true, systemPresent: true, audioKept: audioKept,
                diarized: false, diarizationFailed: false,
                micAudioFailed: mic.audioFailed, systemAudioFailed: system.audioFailed
            ),
            markers: markers,
            segmentStart: start,
            durationSeconds: 60,
            mic: mic,
            system: system,
            sleepInterrupted: sleepInterrupted
        )
    }

    @Test func theTranscriptIsWrittenAndRecordedOnce() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        var recorded: [URL] = []
        guard case .finished(let url, let error) = MeetingFinalisationSteps.run(input(session), recordWritten: { recorded.append($0) }) else {
            Issue.record("expected finished")
            return
        }
        #expect(error == nil)
        #expect(url == session.transcriptURL)
        #expect(recorded == [url])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Hello"))
    }

    @Test func archivesGoOnlyWhenNotKeptAndThereIsText() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        for archive in [session.micArchiveURL, session.systemArchiveURL] { try Data("m4a".utf8).write(to: archive) }
        _ = MeetingFinalisationSteps.run(input(session, paragraphs: [], audioKept: false), recordWritten: { _ in })
        #expect(FileManager.default.fileExists(atPath: session.micArchiveURL.path))
        _ = MeetingFinalisationSteps.run(input(session, audioKept: false), recordWritten: { _ in })
        #expect(!FileManager.default.fileExists(atPath: session.micArchiveURL.path))
        #expect(!FileManager.default.fileExists(atPath: session.systemArchiveURL.path))
    }

    @Test func aFailedTranscriptWriteRecordsAndDeletesNothing() throws {
        let base = try TempFolder.make()
        let session = try session(base)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: session.folder.path)
            TempFolder.remove(base)
        }
        try Data("m4a".utf8).write(to: session.micArchiveURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: session.folder.path)
        var recorded: [URL] = []
        let outcome = MeetingFinalisationSteps.run(input(session, audioKept: false), recordWritten: { recorded.append($0) })
        guard case .failed = outcome else {
            Issue.record("expected failed")
            return
        }
        #expect(recorded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: session.micArchiveURL.path))
    }

    /// The mic needs a retry and the system encode stayed beside its archive:
    /// the error asks for the retry and names the system leftover too.
    @Test func aRetryErrorNamesTheSystemLeftover() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        let leftover = session.folder.appendingPathComponent("system.leftover.m4a")
        let outcome = MeetingFinalisationSteps.run(
            input(session, mic: .init(needsRetry: true), system: .init(leftover: leftover)),
            recordWritten: { _ in }
        )
        guard case .finished(_, let error?) = outcome else {
            Issue.record("expected an error")
            return
        }
        #expect(error.errorDescription?.contains("Try again") == true)
        #expect(error.errorDescription?.contains("system.leftover.m4a") == true)
    }

    @Test func sleepIsReportedWhenNothingElseWentWrong() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        guard case .finished(_, .sleepInterrupted?) = MeetingFinalisationSteps.run(input(session, sleepInterrupted: true), recordWritten: { _ in }) else {
            Issue.record("expected sleepInterrupted")
            return
        }
    }

    @Test func oneSegmentPerMarkerRange() throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let session = try session(base)
        let marker = MeetingCheckpointMarker(
            id: UUID(), capturedAt: start.addingTimeInterval(30), offsetSeconds: 30,
            stemDate: start.addingTimeInterval(30), imageFile: "shot.png"
        )
        _ = MeetingFinalisationSteps.run(input(session, markers: [marker]), recordWritten: { _ in })
        let first = session.folder.appendingPathComponent(MeetingSegmentWriter.fileName(chunkStart: start))
        let second = session.folder.appendingPathComponent(MeetingSegmentWriter.fileName(chunkStart: start.addingTimeInterval(31)))
        #expect(try String(contentsOf: first, encoding: .utf8).contains("Hello"))
        #expect(try String(contentsOf: second, encoding: .utf8).contains("Hi"))
    }

    @Test(arguments: [
        (false, MeetingFinalisationSteps.Track(), MeetingFinalisationSteps.Track(), false),
        (true, MeetingFinalisationSteps.Track(), MeetingFinalisationSteps.Track(), true),
        (false, MeetingFinalisationSteps.Track(archiveExisted: true), MeetingFinalisationSteps.Track(), true),
        (false, MeetingFinalisationSteps.Track(), MeetingFinalisationSteps.Track(needsRetry: true), true),
        (false, MeetingFinalisationSteps.Track(leftover: URL(fileURLWithPath: "/x/mic.leftover.m4a")), MeetingFinalisationSteps.Track(), true),
    ])
    func whenAudioIsKept(setting: Bool, mic: MeetingFinalisationSteps.Track, system: MeetingFinalisationSteps.Track, kept: Bool) {
        #expect(MeetingFinalisationSteps.keepsAudio(setting: setting, mic: mic, system: system) == kept)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/MeetingFinalisationStepsTests 2>&1 | tail -20`
Expected: build FAILS ("cannot find 'MeetingFinalisationSteps' in scope").

- [ ] **Step 3: Write MeetingFinalisationSteps**

Create `Roger/Services/MeetingRecording/MeetingFinalisationSteps.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingFinalisation")

/// The file steps of a meeting finalisation after transcription: segment
/// files, `transcript.md`, the change record, the archive cleanup and the
/// error the menu bar shows. `MeetingRecordingService` keeps capture,
/// encoding, transcription and the UI state.
@MainActor
enum MeetingFinalisationSteps {
    /// What happened to one track's audio before transcription.
    struct Track: Equatable, Sendable {
        /// Chunks were kept for a retry (the encode failed or some chunks
        /// could not be read).
        var needsRetry = false
        /// The new encode stayed beside the archive (`mic.leftover.m4a`).
        var leftover: URL?
        /// The archive existed before this run; it may be the only copy.
        var archiveExisted = false

        /// The transcript does not cover all of this track's audio.
        var audioFailed: Bool { needsRetry || leftover != nil }
    }

    struct Input {
        let session: MeetingSession
        let paragraphs: [MeetingTranscriptMerger.Paragraph]
        let metadata: MeetingTranscriptWriter.Metadata
        let markers: [MeetingCheckpointMarker]
        /// `markers.json`'s start time, else the session's.
        let segmentStart: Date
        let durationSeconds: Int
        let mic: Track
        let system: Track
        let sleepInterrupted: Bool
    }

    enum Outcome {
        /// `transcript.md` is on disk. `error` is what the menu bar shows
        /// (nil: nothing).
        case finished(transcript: URL, error: MeetingRecordingError?)
        /// `transcript.md` could not be written. Nothing was recorded and
        /// no audio was deleted, so a retry can run.
        case failed(String)
    }

    /// All audio stays when the setting says so, when an archive existed
    /// before this run (it may be the only copy) or when a track failed (a
    /// retry needs the other track's archive). The transcript then lists
    /// exactly the files that stay on disk.
    static func keepsAudio(setting: Bool, mic: Track, system: Track) -> Bool {
        setting || mic.archiveExisted || system.archiveExisted || mic.audioFailed || system.audioFailed
    }

    /// `recordWritten` runs once, right after `transcript.md` is on disk.
    static func run(_ input: Input, recordWritten: (URL) -> Void) -> Outcome {
        if !input.markers.isEmpty {
            writeSegments(input)
        }
        let transcriptURL: URL
        do {
            transcriptURL = try MeetingTranscriptWriter.write(paragraphs: input.paragraphs, metadata: input.metadata, markers: input.markers)
        } catch {
            return .failed(error.localizedDescription)
        }
        recordWritten(transcriptURL)

        if !input.metadata.audioKept, !input.paragraphs.isEmpty {
            // Only after the transcript exists: the CAF chunks are already
            // gone, so these archives were the last copy of the audio.
            try? FileManager.default.removeItem(at: input.session.micArchiveURL)
            try? FileManager.default.removeItem(at: input.session.systemArchiveURL)
        }

        // Kept chunks: the session shows up again for a retry. A leftover
        // file only: the audio is safe there, nothing to retry.
        let error = MeetingRecordingError.afterFinalisation(
            micNeedsRetry: input.mic.needsRetry,
            systemNeedsRetry: input.system.needsRetry,
            setAside: [input.mic.leftover, input.system.leftover].compactMap { $0?.lastPathComponent }
        ) ?? (input.sleepInterrupted ? .sleepInterrupted : nil)
        return .finished(transcript: transcriptURL, error: error)
    }

    /// Rewrites every segment from the full pass (drafts are replaced, a
    /// stable segment is moved aside first). A segment whose range has no
    /// speech is removed when it is a draft, else moved aside.
    private static func writeSegments(_ input: Input) {
        let folder = input.session.folder
        for chunk in MeetingCheckpointStore.chunks(sessionStartedAt: input.segmentStart, markers: input.markers) {
            let paragraphs = input.paragraphs.filter { chunk.range.contains(Double($0.startTime)) }
            guard !paragraphs.isEmpty else {
                MeetingSegmentWriter.removeIfExists(chunkStart: chunk.start, folder: folder)
                continue
            }
            do {
                try MeetingSegmentWriter.write(
                    paragraphs: paragraphs,
                    sessionStartedAt: input.segmentStart,
                    chunkStart: chunk.start,
                    chunkEnd: input.segmentStart.addingTimeInterval(
                        chunk.range.upperBound.isFinite ? chunk.range.upperBound : Double(input.durationSeconds)
                    ),
                    folder: folder,
                    provisional: false
                )
            } catch {
                logger.warning("Segment write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
```

- [ ] **Step 4: The service uses it**

In `Roger/Services/MeetingRecording/MeetingRecordingService.swift`, `runFinalisationPipeline(sleepInterrupted:)`:

Replace the two lets `micAudioFailed` and `systemAudioFailed` (with their comment) by:

```swift
        // A track's transcript is incomplete when chunks were kept for a
        // retry or a leftover file stayed beside the archive.
        let micTrack = MeetingFinalisationSteps.Track(
            needsRetry: micOutcome?.needsRetry ?? false, leftover: micLeftover, archiveExisted: micPreexisting
        )
        let systemTrack = MeetingFinalisationSteps.Track(
            needsRetry: systemOutcome?.needsRetry ?? false, leftover: systemLeftover, archiveExisted: systemPreexisting
        )
```

Replace the `audioKept` let (with its comment) by:

```swift
        let audioKept = MeetingFinalisationSteps.keepsAudio(setting: appState.keepMeetingAudio, mic: micTrack, system: systemTrack)
```

In the `MeetingTranscriptWriter.Metadata(...)` call, use `micAudioFailed: micTrack.audioFailed` and `systemAudioFailed: systemTrack.audioFailed`.

Replace everything from the comment `// Screenshot checkpoints: rewrite every segment md ...` down to the end of the function (the segment loop, the transcript write, `onTranscriptWritten`, the archive removal, the error decision and the closing lines) with:

```swift
        let outcome = MeetingFinalisationSteps.run(
            MeetingFinalisationSteps.Input(
                session: session,
                paragraphs: paragraphs,
                metadata: metadata,
                markers: markers,
                segmentStart: checkpointFile?.sessionStartedAt ?? session.startedAt,
                durationSeconds: durationSeconds,
                mic: micTrack,
                system: systemTrack,
                sleepInterrupted: sleepInterrupted
            ),
            recordWritten: { [weak self] url in self?.onTranscriptWritten?(url) }
        )
        switch outcome {
        case .failed(let reason):
            failFinalisation(reason, session: session)
            return
        case .finished(_, let error):
            state = error.map { .error($0) } ?? .idle
        }
        lastSession = session
        self.session = nil
        checkpointStore = nil
        logger.notice("Meeting recording finalised at \(session.folder.path, privacy: .public)")
    }
```

- [ ] **Step 5: Run the tests and build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass, no warnings about unused variables in `runFinalisationPipeline`.

- [ ] **Step 6: Manual check**

Debug-run Roger, record a 20-second meeting with one screenshot drop, stop: `transcript.md` and two segment files appear, `<library>/.roger/changes.jsonl` gets one `created` line for the meeting, the menu bar shows no error.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/Services/MeetingRecording/MeetingFinalisationSteps.swift Roger/Services/MeetingRecording/MeetingRecordingService.swift Roger/RogerTests/MeetingFinalisationStepsTests.swift Roger/Roger.xcodeproj
git commit -m "refactor: move the meeting finalisation file steps into a tested type"
```

---

### Task 21: The test host does not build AppCoordinator

#10: under tests the app does not build the full `AppCoordinator`, so the test host never reads the real settings or library folder (Ruling 18). Today `RogerApp.body` builds `Settings { SettingsView().environment(sharedCoordinator) }`, which creates the global coordinator even though the app delegate returns early under XCTest.

**Files:**
- Modify: `Roger/App/RogerApp.swift` (`AppLaunch`, `body`, `applicationDidFinishLaunching`)
- Modify: `Roger/App/AppCoordinator.swift` (DEBUG counter)
- Test: new `Roger/RogerTests/TestHostTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: nothing new.
- Produces: `enum AppLaunch { static var isRunningTests: Bool }`; `AppCoordinator.instancesCreated: Int` (DEBUG only, main actor).

- [ ] **Step 1: Count coordinators (DEBUG)**

In `Roger/App/AppCoordinator.swift`, add before `init()`:

```swift
    #if DEBUG
    /// How many coordinators this process built. The test host must build none.
    private(set) static var instancesCreated = 0
    #endif
```

and as the first lines of `init()`:

```swift
        #if DEBUG
        Self.instancesCreated += 1
        #endif
```

- [ ] **Step 2: Write the failing test**

Create `Roger/RogerTests/TestHostTests.swift`:

```swift
import Testing
@testable import Roger

@MainActor
struct TestHostTests {
    /// The tests run inside Roger.app. Building the coordinator there would
    /// read the developer's real settings and library folder.
    @Test func theTestHostBuildsNoCoordinator() {
        #expect(AppLaunch.isRunningTests)
        #expect(AppCoordinator.instancesCreated == 0)
    }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodegen generate && git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/TestHostTests 2>&1 | tail -20`
Expected: build FAILS (`AppLaunch` does not exist). With only `AppLaunch` added (Step 4, first part), the test fails with `instancesCreated == 1`. If it passes at that point (SwiftUI did not evaluate the Settings content), keep the guard of Step 4 anyway and note it in the task report: the test still pins the behavior.

- [ ] **Step 4: Build no coordinator under tests**

In `Roger/App/RogerApp.swift`, add after `private let appLogger = ...`:

```swift
enum AppLaunch {
    /// Unit tests run inside Roger.app.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
```

Replace `RogerApp.body`:

```swift
    var body: some Scene {
        Settings {
            // Under tests the settings must not build the coordinator: it
            // reads the real settings and the library folder.
            if AppLaunch.isRunningTests {
                EmptyView()
            } else {
                SettingsView()
                    .environment(sharedCoordinator)
            }
        }
        .windowResizability(.contentMinSize)
    }
```

In `applicationDidFinishLaunching`, replace the XCTest check:

```swift
        if AppLaunch.isRunningTests {
            return
        }
```

- [ ] **Step 5: Run all tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass, `TestHostTests` too.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git diff --stat Roger/Resources/Roger.entitlements   # must print nothing
git add Roger/App/RogerApp.swift Roger/App/AppCoordinator.swift Roger/RogerTests/TestHostTests.swift Roger/Roger.xcodeproj
git commit -m "test: keep the test host from building the app coordinator"
```

---

### Task 22: Agents tab work off the main actor; consumers without a change log

Finding 3: the `roger-mcp` path check, Start Over and Forget run off the main actor. Consumers are listed even when `changes.jsonl` is missing.

**Files:**
- Modify: `Roger/Services/Agents/AgentsStatus.swift` (`read(root:)`)
- Modify: `Roger/Services/Agents/AgentsController.swift` (`init`, `live()`)
- Modify: `Roger/UI/AgentsSettingsView.swift`
- Test: `Roger/RogerTests/AgentsStatusTests.swift`

**Interfaces:**
- Consumes: `RogerMCPLocation.choose(appBundle:links:)`, `BundledSkill.load()` (existing).
- Produces: `AgentsController.init(home:installer:runner:appBundle:searchPath:links:executableChoice: RogerMCPLocation.Choice? = nil)`; `static func live() async -> AgentsController?` (was synchronous).

- [ ] **Step 1: Write the failing test**

Add to `AgentsStatusTests`:

```swift
    /// The change log is gone (or unreadable): the consumers are still
    /// listed, so they can be started over or forgotten.
    @Test func consumersAreListedWithoutAChangeLog() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        try ConsumerBookmarks(root: root).ack("crystalline", upTo: 4, now: now)
        let status = AgentsLibraryStatus.read(root: root)
        #expect(!status.isSetUp)
        #expect(status.consumers == [AgentsConsumerRow(name: "crystalline", seq: 4, updatedAt: now, openEvents: 0)])
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/AgentsStatusTests 2>&1 | tail -20`
Expected: FAIL (`consumers` is empty without a change log).

- [ ] **Step 3: List consumers without a log**

In `Roger/Services/Agents/AgentsStatus.swift`, replace `read(root:)`:

```swift
    /// Reads the change log and the bookmarks. Consumers are listed even
    /// when `changes.jsonl` is missing or unreadable, so they can still be
    /// started over or forgotten.
    static func read(root: URL) -> AgentsLibraryStatus {
        let log = try? ChangeLogFile.readEvents(root: root)
        let events = log ?? []
        let consumers = ConsumerBookmarks(root: root).all().map { named in
            AgentsConsumerRow(
                name: named.name,
                seq: named.bookmark.seq,
                updatedAt: named.bookmark.updatedAt,
                openEvents: events.filter { $0.seq > named.bookmark.seq }.count
            )
        }
        return AgentsLibraryStatus(
            libraryPath: root.path,
            isSetUp: log != nil,
            eventCount: events.count,
            lastEventAt: events.max { $0.seq < $1.seq }?.at,
            consumers: consumers
        )
    }
```

- [ ] **Step 4: Look up the skill and the path off the main actor**

In `Roger/Services/Agents/AgentsController.swift`, replace `init(...)` and `live()`:

```swift
    /// `executableChoice` is looked up from `appBundle` and `links` when
    /// not given (`live()` looks it up off the main actor).
    init(
        home: URL,
        installer: SkillInstaller,
        runner: any CommandRunner,
        appBundle: URL,
        searchPath: [String]? = nil,
        links: [String] = RogerMCPLocation.homebrewLinks,
        executableChoice: RogerMCPLocation.Choice? = nil
    ) {
        self.home = home
        self.installer = installer
        self.runner = runner
        self.searchPath = searchPath
        self.executableChoice = executableChoice ?? RogerMCPLocation.choose(appBundle: appBundle, links: links)
        self.appBundle = appBundle
    }

    /// Nil when this copy of Roger has no bundled skill. Reads the skill
    /// and checks the `roger-mcp` paths off the main actor.
    static func live() async -> AgentsController? {
        let appBundle = Bundle.main.bundleURL
        let found = await Task.detached(priority: .userInitiated) { () -> (BundledSkill, RogerMCPLocation.Choice)? in
            guard let skill = BundledSkill.load() else { return nil }
            return (skill, RogerMCPLocation.choose(appBundle: appBundle))
        }.value
        guard let (skill, choice) = found else { return nil }
        return AgentsController(
            home: FileManager.default.homeDirectoryForCurrentUser,
            installer: .live(skill: skill),
            runner: ProcessCommandRunner(),
            appBundle: appBundle,
            executableChoice: choice
        )
    }
```

In `Roger/UI/AgentsSettingsView.swift`:

Replace the computed property `executableChoice` with a state:

```swift
    /// Looked up off the main actor in `.task` (it checks files).
    @State private var manualChoice: RogerMCPLocation.Choice?
```

In `.task`, replace `agents = AgentsController.live()` with `agents = await AgentsController.live()`, and add after the `if !agentsLoaded { ... }` block:

```swift
            if manualChoice == nil {
                let bundle = Bundle.main.bundleURL
                manualChoice = await Task.detached { RogerMCPLocation.choose(appBundle: bundle) }.value
            }
```

In `manualSetupCard`, switch over the state:

```swift
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
```

Replace `perform(_:)`:

```swift
    /// The bookmark files are written off the main actor.
    private func perform(_ action: ConsumerAction) {
        let bookmarks = ConsumerBookmarks(root: root)
        Task {
            do {
                try await Task.detached {
                    switch action {
                    case .startOver(let name): try bookmarks.reset(name)
                    case .forget(let name): try bookmarks.forget(name)
                    }
                }.value
            } catch {
                actionError = error.localizedDescription
            }
            reload()
        }
    }
```

(`ConsumerAction` holds only strings, so it is `Sendable`. If the compiler asks, add `Sendable` to its declaration.)

- [ ] **Step 5: Run the tests and build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/AgentsStatusTests -only-testing:RogerTests/HarnessRegistrationTests 2>&1 | tail -20`
Expected: all pass (`HarnessRegistrationTests` build `AgentsController` through the unchanged parameters).

- [ ] **Step 6: Manual check**

Debug-run Roger, Settings > Agents: the manual setup commands show (after a short spinner at most). Delete `<library>/.roger/changes.jsonl` by hand: the Consumers card still lists the consumers, Start Over and Forget work.

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Agents/AgentsStatus.swift Roger/Services/Agents/AgentsController.swift Roger/UI/AgentsSettingsView.swift Roger/RogerTests/AgentsStatusTests.swift
git commit -m "fix: keep file work of the Agents tab off the main thread"
```

---

### Task 23: Codex TOML with comments and quoted headers

Finding 5: the Codex TOML reader accepts a trailing `# comment` after the command and a quoted `[mcp_servers."roger"]` header (Ruling 22).

**Files:**
- Modify: `Roger/Services/Agents/HarnessRegistration.swift` (`tomlCommand`, three new helpers)
- Test: `Roger/RogerTests/HarnessRegistrationTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HarnessRegistration.tomlTableName(_ line: String) -> [String]?`, `HarnessRegistration.tomlString(_ text: String) -> (String, Substring)?`.

- [ ] **Step 1: Write the failing tests**

Add to `HarnessRegistrationTests`:

```swift
    @Test func codexTOMLWithCommentsAndQuotedHeaders() {
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = \"/a/roger-mcp\" # added by Roger\n") == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.\"roger\"]\ncommand = \"/a/roger-mcp\"\n") == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[ mcp_servers . 'roger' ] # Roger\ncommand='/a/roger-mcp'\n") == .command("/a/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\n# command = \"/old\"\ncommand = \"/a/#1/roger-mcp\"\n") == .command("/a/#1/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = \"/a/\\\"x\\\"/roger-mcp\"\n") == .command("/a/\"x\"/roger-mcp"))
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.\"roger.other\"]\ncommand = \"x\"\n") == .absent)
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = \"/a/roger-mcp\" trailing\n") == .unreadable)
        #expect(HarnessRegistration.tomlCommand("[mcp_servers.roger]\ncommand = [\"/a/roger-mcp\"]\n") == .unreadable)
    }

    @Test func tomlTableNames() {
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.roger]") == ["mcp_servers", "roger"])
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.\"roger\"] # x") == ["mcp_servers", "roger"])
        #expect(HarnessRegistration.tomlTableName("[[mcp_servers]]") == nil)
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.roger] x") == nil)
        #expect(HarnessRegistration.tomlTableName("[mcp_servers.\"roger]") == nil)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/HarnessRegistrationTests 2>&1 | tail -20`
Expected: build FAILS (`tomlTableName` does not exist).

- [ ] **Step 3: Implement**

In `Roger/Services/Agents/HarnessRegistration.swift`, replace `tomlCommand(_:)` with:

```swift
    /// `command = "..."` inside `[mcp_servers.roger]`. Accepts what Codex
    /// and people write: spaces, a `# comment` after the header or the
    /// value, and the header as `[mcp_servers."roger"]` or
    /// `[mcp_servers.'roger']`. The text comes from `TextFile` (LF).
    static func tomlCommand(_ text: String) -> ConfigLookup {
        var inSection = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = tomlTableName(line) == ["mcp_servers", "roger"]
                continue
            }
            guard inSection, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, unquotedTOMLKey(parts[0]) == "command" else { continue }
            guard let (value, rest) = tomlString(parts[1]) else { return .unreadable }
            let tail = rest.trimmingCharacters(in: .whitespaces)
            guard tail.isEmpty || tail.hasPrefix("#") else { return .unreadable }
            return .command(value)
        }
        return .absent
    }

    /// The dotted parts of `[a."b"]`, unquoted. Nil for `[[array]]` or a
    /// broken line. Spaces and a `# comment` may follow the `]`.
    static func tomlTableName(_ line: String) -> [String]? {
        guard line.hasPrefix("["), !line.hasPrefix("[[") else { return nil }
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var rest: Substring?
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let ch = line[index]
            index = line.index(after: index)
            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if ch == "]" {
                rest = line[index...]
                break
            } else {
                current.append(ch)
            }
        }
        guard let rest, quote == nil else { return nil }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        return parts + [current.trimmingCharacters(in: .whitespaces)]
    }

    private static func unquotedTOMLKey(_ key: String) -> String {
        guard key.count >= 2, let first = key.first, first == "\"" || first == "'", key.last == first else { return key }
        return String(key.dropFirst().dropLast())
    }

    /// A basic (`"..."`, with `\\` and `\"` escapes) or literal (`'...'`)
    /// string at the start of `text`, and what follows it.
    static func tomlString(_ text: String) -> (String, Substring)? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let ch = text[index]
            if ch == quote {
                return (value, text[text.index(after: index)...])
            }
            if quote == "\"", ch == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                switch text[next] {
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "t": value.append("\t")
                default: value.append("\\"); value.append(text[next])
                }
                index = text.index(after: next)
                continue
            }
            value.append(ch)
            index = text.index(after: index)
        }
        return nil
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/HarnessRegistrationTests 2>&1 | tail -20`
Expected: all pass (`readsCodexTOML` and `readsACRLFCodexConfig` too).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Agents/HarnessRegistration.swift Roger/RogerTests/HarnessRegistrationTests.swift
git commit -m "fix: read Codex configs with comments and quoted table names"
```

---

### Task 24: recordWritten takes the root the writer used

Finding 6: the change event goes into the log of the library the file was written into, even when the library setting changed in between (Ruling 19).

**Files:**
- Modify: `Roger/Services/Library/LibraryChangeRecorder.swift` (`recordWritten`, `enqueue`)
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (`onTranscriptWritten`, session root)
- Modify: `Roger/App/AppCoordinator.swift` (three callers)
- Modify: `Roger/UI/Library/LibraryDetailView.swift` (two callers)
- Test: `Roger/RogerTests/LibraryChangeRecorderTests.swift`

**Interfaces:**
- Consumes: `LogEntrySaver` (Task 18), `MeetingFinalisationSteps` (Task 20).
- Produces: `LibraryChangeRecorder.recordWritten(markdownURL: URL, kind: LibraryItemKind, root: URL)` (the old two-argument form is gone); `MeetingRecordingService.onTranscriptWritten: (@MainActor (_ transcript: URL, _ root: URL) -> Void)?`.

- [ ] **Step 1: Write the failing test and update the callers in the tests**

In `Roger/RogerTests/LibraryChangeRecorderTests.swift`, add the root to every `recordWritten` call:

- `recorder.recordWritten(markdownURL: url, kind: .log)` becomes `recorder.recordWritten(markdownURL: url, kind: .log, root: root)`
- both `recorder.recordWritten(markdownURL: transcript, kind: .meeting)` get `, root: root`
- `recorder.recordWritten(markdownURL: try writeLog(rootA, at: date, text: "in A"), kind: .log)` gets `, root: rootA`
- `recorder.recordWritten(markdownURL: newInB, kind: .log)` gets `, root: rootB`
- in `aFailedWriteDoesNotBlockLaterWrites`, the call gets `, root: root`
- in `noEnvironmentMeansNoWrites`, the call gets `, root: folder`

Add to `LibraryChangeRecorderTests`:

```swift
    /// A log entry written into library A just before the user switched to
    /// B is recorded in A's log under its library key, not in B's.
    @Test func aWriteGoesToTheLibraryItWasWrittenTo() async throws {
        let home = try TempFolder.make()
        defer { TempFolder.remove(home) }
        let rootA = home.appendingPathComponent("A", isDirectory: true)
        let rootB = home.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let box = RootBox(rootA)
        let recorder = recorder(box, registry: home.appendingPathComponent("external.json"))
        let url = try writeLog(rootA, at: date, text: "in A")
        box.root = rootB
        recorder.recordWritten(markdownURL: url, kind: .log, root: rootA)
        await recorder.waitUntilIdle()
        let inA = try ChangeLogFile.readEvents(root: rootA)
        #expect(inA.map(\.key) == [ChangeKey.subject(markdownURL: url, kind: .log, root: rootA).key])
        #expect(inA.first?.key.hasPrefix("Logs/") == true)
        #expect(!FileManager.default.fileExists(atPath: ChangeLogFile.url(root: rootB).path))
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryChangeRecorderTests 2>&1 | tail -20`
Expected: build FAILS ("extra argument 'root' in call").

- [ ] **Step 3: The recorder**

In `Roger/Services/Library/LibraryChangeRecorder.swift`, replace `recordWritten(markdownURL:kind:)`:

```swift
    /// The item's Markdown is on disk (new, edited, renamed or rewritten).
    /// `root` is the library root the writer used: the event goes into that
    /// library's log, also when the library setting changed meanwhile.
    func recordWritten(markdownURL: URL, kind: LibraryItemKind, root: URL) {
        guard let env = environment?() else { return }
        let subject = ChangeKey.subject(markdownURL: markdownURL, kind: kind, root: root)
        enqueue(env, root: root) { log in
            try await log.record(.written, subject)
        }
    }
```

and the head of `enqueue` (up to and including the `caughtUpRoot` assignment):

```swift
    /// Runs `operation` on the log of `root` (default: the current root).
    /// Only the current root is caught up.
    private func enqueue(
        _ env: LibraryChangeEnvironment,
        root: URL? = nil,
        _ operation: @escaping @Sendable (ChangeLog) async throws -> Void
    ) {
        let target = root ?? env.layout.root
        let rootKey = target.standardizedFileURL.path
        let isCurrent = rootKey == env.layout.root.standardizedFileURL.path
        let log = logs[rootKey] ?? ChangeLog(root: target)
        logs[rootKey] = log
        let needsCatchUp = isCurrent && caughtUpRoot != rootKey
        if isCurrent { caughtUpRoot = rootKey }
```

- [ ] **Step 4: The writers pass their root**

`Roger/Services/MeetingRecording/MeetingRecordingService.swift`:

```swift
    /// Called after `transcript.md` is on disk, on the first finalisation
    /// and on every retry, with the library root the session was written
    /// under. The coordinator records the change for agents.
    @ObservationIgnored var onTranscriptWritten: (@MainActor (_ transcript: URL, _ root: URL) -> Void)?
```

Add next to `private var session: MeetingSession?`:

```swift
    /// The library root `start()` created the session under (recovery: the
    /// root at the time of the retry).
    @ObservationIgnored private var sessionRoot: URL?
```

In `start()`, replace `let parent = appState.libraryLayout.monthFolder(.meetings, for: startedAt)` with:

```swift
        let layout = appState.libraryLayout
        let parent = layout.monthFolder(.meetings, for: startedAt)
```

and after `self.session = session` add `sessionRoot = layout.root`. In `finaliseRecovered(_:)`, after `self.session = session` add `sessionRoot = appState.libraryLayout.root`. In `runFinalisationPipeline`, before `let outcome = MeetingFinalisationSteps.run(`:

```swift
        let root = sessionRoot ?? appState.libraryLayout.root
```

and change the closure to `recordWritten: { [weak self] url in self?.onTranscriptWritten?(url, root) }`.

`Roger/App/AppCoordinator.swift`:

- in `init()`:

```swift
        meetingRecorder.onTranscriptWritten = { [weak self] url, root in
            self?.libraryChanges.recordWritten(markdownURL: url, kind: .meeting, root: root)
        }
```

- in `saveLogEntry`, the saver's closure: `libraryChanges.recordWritten(markdownURL: url, kind: .log, root: layout.root)`
- in `runFileTranscription`, take the layout once: before `let outputURL = try TranscriptOutputWriter.write(` add `let layout = appState.libraryLayout`, pass `layout: layout` to the writer, and record with `libraryChanges.recordWritten(markdownURL: outputURL, kind: .transcript, root: layout.root)`.

`Roger/UI/Library/LibraryDetailView.swift`, both calls (save and rename):

```swift
                coordinator.libraryChanges.recordWritten(
                    markdownURL: item.url, kind: item.kind, root: coordinator.appState.libraryLayout.root
                )
```

(The window's index always follows the current root, see `LibraryWindowController.refreshScope()`.)

- [ ] **Step 5: Run the tests and build**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Library/LibraryChangeRecorder.swift Roger/Services/MeetingRecording/MeetingRecordingService.swift Roger/App/AppCoordinator.swift Roger/UI/Library/LibraryDetailView.swift Roger/RogerTests/LibraryChangeRecorderTests.swift
git commit -m "fix: record a change in the library the file was written to"
```

---

### Task 25: One rule for a file found twice

Finding 7: the library index and `LibraryScanner` use one rule for a file found twice: the first find wins (Ruling 20). A change of an extra folder itself or of the external-transcripts list reads everything again (both are rare), so the rule also holds after them.

**Files:**
- Modify: `Roger/Services/Library/LibraryIndex.swift` (`reload`, `scanAll`, drop `scanExternal`)
- Test: `Roger/RogerTests/LibraryIndexTests.swift`

**Interfaces:**
- Consumes: `LibraryScanner.scanAll(scope:externalFiles:)` (existing).
- Produces: no new names.

- [ ] **Step 1: Write the failing test**

Add to `LibraryIndexTests`:

```swift
    /// An extra folder that is also a Logs month folder: a file without tags
    /// is found twice. The index keeps what `LibraryScanner` keeps (the
    /// first find, a log), also after the extra folder or the external list
    /// changed.
    @Test func aFileFoundTwiceKeepsItsFirstItem() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        let month = layout.monthFolder(.logs, for: date)
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        let note = month.appendingPathComponent("note.md")
        try "# Note\n\nNo tags here\n".write(to: note, atomically: true, encoding: .utf8)
        let registry = ExternalTranscriptRegistry(fileURL: base.appendingPathComponent("Support/external-transcripts.json"))
        try registry.add(note)
        let scope = LibraryScanScope(layout: layout, extraFolders: [month])
        let scanner = LibraryScanner.scanAll(scope: scope, externalFiles: [note])
        #expect(scanner.map(\.kind) == [.log])

        let index = makeIndex(layout, extras: [month], external: { registry.existingFiles() }, listURL: registry.fileURL)
        #expect(await index.items().map(\.kind) == [.log])
        await index.apply(changedPaths: [month.path])
        #expect(await index.items().map(\.kind) == [.log])
        await index.apply(changedPaths: [registry.fileURL.path])
        #expect(await index.items().map(\.kind) == [.log])
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryIndexTests 2>&1 | tail -20`
Expected: FAIL in `aFileFoundTwiceKeepsItsFirstItem`: the index keeps the last find (a transcript).

- [ ] **Step 3: Implement**

In `Roger/Services/Library/LibraryIndex.swift`, `reload(_:)`, replace the `.extraFolder` and `.externalList` cases:

```swift
        case .extraFolder:
            // Rare (the extra folder itself appeared, went or was renamed).
            // A full read keeps the scanner's rule for a file found twice.
            itemsByID = scanAll()
        case .externalList:
            itemsByID = scanAll()
            // A new external transcript may live in a folder nobody watches yet.
            if watchesFileSystem { restartWatcherIfNeeded() }
```

Replace `scanAll()` and delete `scanExternal()`:

```swift
    /// The scanner's order and rule: Logs, Transcripts, Meetings, extra
    /// folders, external list; a file found twice keeps its first item.
    private func scanAll() -> [String: LibraryItem] {
        let files = externalFiles()
        let items = LibraryScanner.scanAll(scope: scope, externalFiles: files)
        externalIDs = Set(files.map { LibraryPath.canonical($0) }).intersection(items.map(\.id))
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryIndexTests -only-testing:RogerTests/LibraryIndexStoreTests 2>&1 | tail -20`
Expected: all pass (`externalListChangeAddsTheTranscript` and `findsEveryKindAndPlace` too).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/Services/Library/LibraryIndex.swift Roger/RogerTests/LibraryIndexTests.swift
git commit -m "fix: keep the first find of a file in the library index like the scanner"
```

---

### Task 26: ingest-roger.sh checks its arguments and its last line; release checks the helper's team and timestamp

Finding 8: `scripts/ingest-roger.sh` validates the run count (a positive integer, else exit 2) and reads `RESULT:` only from the last non-empty line (Ruling 23). Finding 9: `release.yml` checks that `roger-mcp` has the app's TeamIdentifier and a secure timestamp.

**Files:**
- Modify: `scripts/ingest-roger.sh`
- Create: `scripts/test-ingest-roger.sh`
- Modify: `.github/workflows/release.yml` (step "Verify roger-mcp signature")

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/test-ingest-roger.sh` (exit 0 when all checks pass).

- [ ] **Step 1: Write the failing test script**

Create `scripts/test-ingest-roger.sh` and make it executable (`chmod +x scripts/test-ingest-roger.sh`):

```bash
#!/usr/bin/env bash
# Checks scripts/ingest-roger.sh with fake Claude Code binaries.
# Usage: scripts/test-ingest-roger.sh   (exits 0 when every check passes)
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ingest-roger.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

# fake <name> <output>: a claude that prints <output> and exits 0.
fake() {
  printf '#!/bin/sh\nprintf "%%b" %q\n' "$2" > "$work/$1"
  chmod +x "$work/$1"
}

# check <expected exit> <description> <args...>; CLAUDE_BIN must be set.
check() {
  local expected=$1 description=$2
  shift 2
  bash "$script" "$@" > /dev/null 2>&1
  local status=$?
  if [ "$status" -ne "$expected" ]; then
    echo "FAIL: $description (exit $status, expected $expected)"
    failures=$((failures + 1))
  else
    echo "ok: $description"
  fi
}

fake done 'Ingested 3 entries.\nRESULT: ok\n\n'
fake quoted 'The entry said: RESULT: ok\nRESULT: ok\nI also wrote a summary.\n'
fake failed 'RESULT: failed: crystalline is not reachable\n'
fake spaces 'RESULT: ok   \n'

CLAUDE_BIN="$work/done" check 0 "RESULT: ok on the last line ends the loop" notes 3
CLAUDE_BIN="$work/spaces" check 0 "trailing spaces after RESULT: ok are fine" notes 3
CLAUDE_BIN="$work/quoted" check 1 "a RESULT line that is not the last line does not count" notes 3
CLAUDE_BIN="$work/failed" check 1 "RESULT: failed fails" notes 3
CLAUDE_BIN="$work/done" check 2 "max-runs 0 is refused" notes 0
CLAUDE_BIN="$work/done" check 2 "max-runs abc is refused" notes abc
CLAUDE_BIN="$work/done" check 2 "max-runs -1 is refused" notes -1
CLAUDE_BIN="$work/done" check 2 "max-runs 3x is refused" notes 3x
CLAUDE_BIN="$work/done" check 2 "a missing domain is refused"

[ "$failures" -eq 0 ]
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash /Users/jordi/git/roger/scripts/test-ingest-roger.sh`
Expected: exit 1 with six `FAIL` lines (trailing spaces, a RESULT line that is not the last line, and the four bad `max-runs` values). Checked 2026-10-14 against the current script.

- [ ] **Step 3: Fix the script**

Apply to `scripts/ingest-roger.sh`:

```diff
--- a/scripts/ingest-roger.sh
+++ b/scripts/ingest-roger.sh
@@ -9,9 +9,10 @@
 #   CRYSTALLINE_MCP_SERVER  name of the Crystalline MCP server (default: crystalline)
 #
 # Only the tools of these two servers are allowed. Exits 0 when everything
-# was ingested, 1 when a run failed (the next run repeats the same range).
-# Also exits 0 when max-runs ran out and there is still more: the next call goes on.
-# Installs nothing.
+# was ingested, 1 when a run failed (the next run repeats the same range),
+# 2 for wrong arguments. Also exits 0 when max-runs ran out and there is
+# still more: the next call goes on. A run counts only by its last
+# non-empty line (RESULT: ...). Installs nothing.
 set -euo pipefail
 
 domain="${1:-}"
@@ -20,6 +21,11 @@
   echo "Usage: $0 <crystalline-domain> [max-runs]" >&2
   exit 2
 fi
+if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
+  echo "Usage: $0 <crystalline-domain> [max-runs]" >&2
+  echo "ingest-roger: max-runs must be a whole number of 1 or more, not \"$runs\"." >&2
+  exit 2
+fi
 
 claude_bin="${CLAUDE_BIN:-claude}"
 allowed="mcp__${ROGER_MCP_SERVER:-roger},mcp__${CRYSTALLINE_MCP_SERVER:-crystalline}"
@@ -31,7 +37,9 @@
     exit 1
   fi
   printf '%s\n' "$output"
-  result=$(printf '%s\n' "$output" | grep -E '^RESULT: ' | tail -n 1 || true)
+  # Only the last non-empty line counts: a RESULT line quoted earlier in
+  # the output (or in an entry's text) must not end the loop.
+  result=$(printf '%s\n' "$output" | awk 'NF { last = $0 } END { sub(/[ \t\r]+$/, "", last); print last }')
   case "$result" in
     "RESULT: ok")
       exit 0
@@ -39,8 +47,12 @@
     "RESULT: ok more")
       continue
       ;;
+    "RESULT: failed"*)
+      echo "ingest-roger: $result in run $run" >&2
+      exit 1
+      ;;
     *)
-      echo "ingest-roger: ${result:-no RESULT line} in run $run" >&2
+      echo "ingest-roger: no RESULT line at the end of run $run" >&2
       exit 1
       ;;
   esac
```

The resulting file:

```bash
#!/usr/bin/env bash
# Runs the ingest-roger skill with Claude Code until Roger has nothing new.
#
# Usage: scripts/ingest-roger.sh <crystalline-domain> [max-runs]
#
# Environment:
#   CLAUDE_BIN              Claude Code binary (default: claude)
#   ROGER_MCP_SERVER        name of the Roger MCP server (default: roger)
#   CRYSTALLINE_MCP_SERVER  name of the Crystalline MCP server (default: crystalline)
#
# Only the tools of these two servers are allowed. Exits 0 when everything
# was ingested, 1 when a run failed (the next run repeats the same range),
# 2 for wrong arguments. Also exits 0 when max-runs ran out and there is
# still more: the next call goes on. A run counts only by its last
# non-empty line (RESULT: ...). Installs nothing.
set -euo pipefail

domain="${1:-}"
runs="${2:-10}"
if [ -z "$domain" ]; then
  echo "Usage: $0 <crystalline-domain> [max-runs]" >&2
  exit 2
fi
if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 <crystalline-domain> [max-runs]" >&2
  echo "ingest-roger: max-runs must be a whole number of 1 or more, not \"$runs\"." >&2
  exit 2
fi

claude_bin="${CLAUDE_BIN:-claude}"
allowed="mcp__${ROGER_MCP_SERVER:-roger},mcp__${CRYSTALLINE_MCP_SERVER:-crystalline}"

for ((run = 1; run <= runs; run++)); do
  if ! output=$("$claude_bin" --allowedTools "$allowed" -p "/ingest-roger $domain" 2>&1); then
    printf '%s\n' "$output"
    echo "ingest-roger: claude failed in run $run" >&2
    exit 1
  fi
  printf '%s\n' "$output"
  # Only the last non-empty line counts: a RESULT line quoted earlier in
  # the output (or in an entry's text) must not end the loop.
  result=$(printf '%s\n' "$output" | awk 'NF { last = $0 } END { sub(/[ \t\r]+$/, "", last); print last }')
  case "$result" in
    "RESULT: ok")
      exit 0
      ;;
    "RESULT: ok more")
      continue
      ;;
    "RESULT: failed"*)
      echo "ingest-roger: $result in run $run" >&2
      exit 1
      ;;
    *)
      echo "ingest-roger: no RESULT line at the end of run $run" >&2
      exit 1
      ;;
  esac
done

echo "ingest-roger: there is still more after $runs runs. Run it again later." >&2
exit 0
```

- [ ] **Step 4: Run the test script**

Run: `bash /Users/jordi/git/roger/scripts/test-ingest-roger.sh`
Expected: nine `ok:` lines, exit 0.

- [ ] **Step 5: Check the helper's team and timestamp in release.yml**

In `.github/workflows/release.yml`, step "Verify roger-mcp signature", add after the line `grep -Eq "flags=0x[0-9a-f]*\(.*runtime.*\)" "${{ runner.temp }}/roger-mcp-sign.txt"`:

```yaml
          # The same team as the app, and a secure timestamp (notarization
          # needs it; a signature without one shows "Signed Time=" instead).
          APP_TEAM=$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
          BIN_TEAM=$(sed -n 's/^TeamIdentifier=//p' "${{ runner.temp }}/roger-mcp-sign.txt")
          echo "Roger.app team: $APP_TEAM, roger-mcp team: $BIN_TEAM"
          test -n "$APP_TEAM"
          test "$APP_TEAM" != "not set"
          test "$APP_TEAM" = "$BIN_TEAM"
          grep -q "^Timestamp=" "${{ runner.temp }}/roger-mcp-sign.txt"
```

This cannot run locally: a development signature has no secure timestamp. Check the YAML parses: `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")' && echo ok` (from `/Users/jordi/git/roger`). It runs in the release rehearsal, which is not part of this plan.

- [ ] **Step 6: Commit**

```bash
cd /Users/jordi/git/roger
git add scripts/ingest-roger.sh scripts/test-ingest-roger.sh .github/workflows/release.yml
git commit -m "fix: check ingest script arguments and the helper's signing team"
```

---

### Task 27: Small cleanups: TOON keys, no patterns, a reused formatter, a 512 px icon

Finding 10: the TOON key check rejects a trailing newline (no regex `$`), patterns are not compiled on every call (RogerKit's three regex checks become plain code; `PostProcessor` is not part of the 0.25.0 findings and stays), the session folder date formatter is reused and the Claude Desktop extension icon is 512 px (Ruling 25).

**Files:**
- Modify: `Roger/RogerKit/TOON.swift` (`needsQuotes`, `key`, new helpers)
- Modify: `Roger/RogerKit/SinceParser.swift`
- Modify: `Roger/RogerKit/SessionFolderName.swift`
- Modify: `Roger/Services/Agents/DesktopExtensionBuilder.swift` (`iconPNG`)
- Test: `Roger/RogerKitTests/TOONTests.swift`, `Roger/RogerKitTests/ChangeQueryTests.swift` (`SinceParserTests`), `Roger/RogerTests/DesktopExtensionBuilderTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `TOON.isPlainKey(_:) -> Bool`, `TOON.looksLikeNumber(_:) -> Bool` (internal).

- [ ] **Step 1: Write the failing tests**

Add to `TOONTests`:

```swift
    @Test func keysWithATrailingNewlineAreQuoted() {
        #expect(TOON.key("abc\n") == "\"abc\\n\"")
        #expect(TOON.key("_a1") == "_a1")
        #expect(TOON.key("") == "\"\"")
        #expect(TOON.key("ä") == "\"ä\"")
    }

    @Test(arguments: ["1", "-1", "+2", "3.5", "1e9", "2E-3", "-0.5e+7"])
    func numbersAreQuoted(_ text: String) {
        #expect(TOON.looksLikeNumber(text))
        #expect(TOON.needsQuotes(text))
    }

    @Test(arguments: ["", "-", "1.", ".5", "1e", "1e+", "12a", "1.2.3", "0x10", "١٢"])
    func otherTextIsNoNumber(_ text: String) {
        #expect(!TOON.looksLikeNumber(text))
    }
```

Add to `SinceParserTests` (in `Roger/RogerKitTests/ChangeQueryTests.swift`):

```swift
    @Test func aDayWithANewlineIsNoDay() {
        #expect(SinceParser.parse("2026-10-13\n", now: Date()) == nil)
        #expect(SinceParser.parse("2026-1-13", now: Date()) == nil)
    }
```

Add to `DesktopExtensionBuilderTests`:

```swift
    @Test func theExtensionIconIs512Pixels() throws {
        let rep = try #require(NSBitmapImageRep(data: try pngIcon()))
        #expect(rep.pixelsWide == 512)
        #expect(rep.pixelsHigh == 512)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerKitTests/TOONTests -only-testing:RogerKitTests/SinceParserTests -only-testing:RogerTests/DesktopExtensionBuilderTests 2>&1 | tail -20`
Expected: build FAILS (`looksLikeNumber` does not exist). Without the number tests: `keysWithATrailingNewlineAreQuoted` fails (the regex `$` accepts `abc\n`) and `theExtensionIconIs512Pixels` fails (256).

- [ ] **Step 3: TOON without regex**

In `Roger/RogerKit/TOON.swift`, in `needsQuotes(_:)` replace the regex line with:

```swift
        if looksLikeNumber(text) { return true }
```

Replace `key(_:)` with:

```swift
    /// §7.3: unquoted when it matches `^[A-Za-z_][A-Za-z0-9_.]*$`.
    public static func key(_ name: String) -> String {
        isPlainKey(name) ? name : quoted(name)
    }

    /// `^[A-Za-z_][A-Za-z0-9_.]*$`, checked by hand: a regex `$` also
    /// matches before a final newline, and a pattern would be compiled on
    /// every call.
    static func isPlainKey(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, isLetterOrUnderscore(first) else { return false }
        return scalars.allSatisfy { isLetterOrUnderscore($0) || isDigit($0) || $0 == "." }
    }

    /// `^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$`, checked by hand.
    static func looksLikeNumber(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        func skipSign() {
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
        }
        func digits() -> Int {
            let start = index
            while index < scalars.count, isDigit(scalars[index]) { index += 1 }
            return index - start
        }
        skipSign()
        guard digits() > 0 else { return false }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            guard digits() > 0 else { return false }
        }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            skipSign()
            guard digits() > 0 else { return false }
        }
        return index == scalars.count
    }

    private static func isLetterOrUnderscore(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_"
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
```

- [ ] **Step 4: SinceParser and SessionFolderName**

In `Roger/RogerKit/SinceParser.swift`, replace `if text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {` with `if isDay(text) {` and add before `private extension Character`:

```swift
/// `YYYY-MM-DD` by hand (a regex `$` also accepts a final newline).
private func isDay(_ text: String) -> Bool {
    let characters = Array(text)
    guard characters.count == 10 else { return false }
    return characters.enumerated().allSatisfy { index, character in
        index == 4 || index == 7 ? character == "-" : character.isASCIIDigit
    }
}
```

Replace the two functions of `Roger/RogerKit/SessionFolderName.swift` with:

```swift
    /// Start date from the first 16 characters of the folder name.
    public static func date(for folder: URL) -> Date? {
        let name = folder.lastPathComponent
        guard name.count >= 16 else { return nil }
        return folderFormatter.date(from: String(name.prefix(16)))
    }

    /// `yyyy-MM-dd HH:mm` in local time, used in meeting titles.
    public static func displayDate(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    // Made once: the library reads one folder name per meeting.
    // `DateFormatter` is thread-safe and `Sendable`.
    private static let folderFormatter = formatter("yyyy-MM-dd HH-mm")
    private static let displayFormatter = formatter("yyyy-MM-dd HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
```

- [ ] **Step 5: The 512 px icon**

In `Roger/Services/Agents/DesktopExtensionBuilder.swift`:

```swift
    /// The app icon as a `size` x `size` PNG. 512 px: Claude Desktop shows
    /// extension icons large on Retina screens.
    static func iconPNG(for appBundle: URL, size: Int = 512) -> Data? {
```

- [ ] **Step 6: Run the tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass (`TOONTests.keys`, `SessionFolderNameTests` and the `.mcpb` tests too).

- [ ] **Step 7: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/RogerKit/TOON.swift Roger/RogerKit/SinceParser.swift Roger/RogerKit/SessionFolderName.swift Roger/Services/Agents/DesktopExtensionBuilder.swift Roger/RogerKitTests/TOONTests.swift Roger/RogerKitTests/ChangeQueryTests.swift Roger/RogerTests/DesktopExtensionBuilderTests.swift
git commit -m "fix: quote TOON keys with a newline and draw a 512 px extension icon"
```

---

### Task 28: The missing tests (and a no-op ack that writes nothing)

Finding 11: `ensureFile` leaves an existing log byte for byte, the six tools write nothing in an empty library, the `search` limit clamp, Trash with a failed `.md` and a working `.m4a`. The empty-library test finds that an `ack` that changes nothing still creates `.roger/consumers/` and its lock file; `ack` now returns early without writing.

**Files:**
- Modify: `Roger/RogerKit/ConsumerBookmarks.swift` (`ack`)
- Test: `Roger/RogerKitTests/ChangeLogTests.swift`, `Roger/RogerKitTests/RogerToolsTests.swift`, `Roger/RogerTests/LibraryActionsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no new names.

- [ ] **Step 1: Write the tests**

Add to `ChangeLogTests`:

```swift
    /// `ensureFile` on a log with events (also one cut by a crash) leaves
    /// every byte as it is.
    @Test func ensureFileLeavesAnExistingLogByteForByte() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let log = ChangeLog(root: root)
        try await log.append([PendingChange(event: .created, kind: .log, key: "Logs/a", path: "Logs/a.md")])
        let url = ChangeLogFile.url(root: root)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":2,"at":"#.utf8))
        try handle.close()
        let before = try Data(contentsOf: url)
        try await log.ensureFile()
        #expect(try Data(contentsOf: url) == before)
    }
```

Add to `RogerToolsTests`:

```swift
    /// A library that was set up but has no items yet: no tool writes
    /// anything (no bookmark for an ack of 0, no lock file, no folder).
    @Test func theSixToolsWriteNothingInAnEmptyLibrary() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        try await ChangeLog(root: root).ensureFile()
        func snapshot() throws -> [String: Date] {
            var result: [String: Date] = [:]
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
            while let url = enumerator?.nextObject() as? URL {
                result[url.path] = try url.resourceValues(forKeys: Set(keys)).contentModificationDate
            }
            return result
        }
        let before = try snapshot()
        for (name, arguments) in [
            ("status", [String: ToolValue]()),
            ("get_changes", ["consumer": .string("crystalline")]),
            ("ack", ["consumer": .string("crystalline"), "upTo": .int(0)]),
            ("get_item", ["key": .string("Logs/2026/10/none")]),
            ("list_items", [:]),
            ("search", ["query": .string("supplier")]),
        ] {
            _ = tools(root).call(name, arguments: arguments)
        }
        #expect(try snapshot() == before)
    }

    @Test func searchClampsTheLimitTo100() async throws {
        let root = try TempDir.make()
        defer { TempDir.remove(root) }
        let layout = LibraryLayout(root: root)
        for i in 0..<101 {
            try KitFixtures.log(in: layout, at: KitFixtures.base.addingTimeInterval(Double(i) * 60), text: "Supplier note \(i)")
        }
        try await ChangeLog(root: root).ensureFile()
        let output = tools(root).call("search", arguments: ["query": .string("supplier"), "limit": .int(9_999)])
        #expect(!output.isError)
        #expect(output.text.hasPrefix("results[100]{key,kind,title,date,snippet}:"))
    }
```

Add to `LibraryActionsTests`:

```swift
    /// The `.md` of a log stays (the move failed) while its `.m4a` went: the
    /// log is not reported as deleted, and the message names the `.md`.
    @Test func aFailedMarkdownAndAMovedAudioIsNoDeletion() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let library = layout(root)
        let md = library.root.appendingPathComponent("Logs/2026/10/a.md")
        let m4a = md.deletingPathExtension().appendingPathExtension("m4a")
        try touch(md)
        try touch(m4a)
        let item = LibraryFixtures.item("a", folder: md.deletingLastPathComponent().path)
        let plan = LibraryActions.trashPlan(for: [item], layout: library, extraFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["a.md", "a.m4a"])
        var moved: [URL] = []
        let failed = LibraryActions.moveToTrash(plan.urls) { url in
            if url.pathExtension == "md" { throw CocoaError(.fileWriteNoPermission) }
            moved.append(url)
        }
        #expect(failed.map(\.lastPathComponent) == ["a.md"])
        #expect(moved.map(\.lastPathComponent) == ["a.m4a"])
        #expect(LibraryChangeRecorder.trashedItems([item], plan: plan, failed: failed).isEmpty)
        #expect(LibraryActions.trashFailureMessage(failed) == "Some files could not be moved to the Trash: a.md.")
    }
```

- [ ] **Step 2: Run them**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerKitTests/ChangeLogTests -only-testing:RogerKitTests/RogerToolsTests -only-testing:RogerTests/LibraryActionsTests 2>&1 | tail -20`
Expected: only `theSixToolsWriteNothingInAnEmptyLibrary` fails: `ack` with `upTo: 0` creates `.roger/consumers/` and `.lock` (checked 2026-10-14).

- [ ] **Step 3: A no-op ack writes nothing**

In `Roger/RogerKit/ConsumerBookmarks.swift`, replace the doc comment and the first lines of `ack(_:upTo:now:)` up to `return try withLock {`:

```swift
    /// Moves the bookmark to `upTo` when that is higher. Never backwards.
    /// An `upTo` that is not newer writes nothing, not even the folder or
    /// the lock file (the file is replaced by `rename`, so reading it
    /// without the lock is safe).
    @discardableResult
    public func ack(_ name: String, upTo: Int, now: Date = Date()) throws -> AckResult {
        try validate(name)
        let seen = Self.read(fileURL(name))?.seq ?? 0
        guard upTo > seen else { return AckResult(previous: seen, current: seen) }
        return try withLock {
```

(The check under the lock stays: another process may have moved the bookmark meanwhile.)

- [ ] **Step 4: Run all tests**

Run: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all pass (`concurrentAcksEndAtTheHighest`, `ackNeverMovesBackwards` and `onlyBookmarksAreWritten` too).

- [ ] **Step 5: Commit**

```bash
cd /Users/jordi/git/roger
git add Roger/RogerKit/ConsumerBookmarks.swift Roger/RogerKitTests/ChangeLogTests.swift Roger/RogerKitTests/RogerToolsTests.swift Roger/RogerTests/LibraryActionsTests.swift
git commit -m "test: cover an empty library, the search limit, ensureFile and a half trash"
```

---

## Final checks

Run after Task 28. Nothing here is committed: `AGENTS.md` is a local file.

**Files:**
- Modify (local, not committed): `AGENTS.md`

- [ ] **Step 1: No raw text reads left**

Run: `cd /Users/jordi/git/roger/Roger && grep -rn -e 'String(contentsOf' -e 'encoding: .utf8)' -e 'String(decoding' RogerKit Services App UI RogerMCP | grep -v -e '\.write(' -e 'LLM/'`
Expected: only lines that do not feed a parser: `KeychainManager` (keychain data), `McpCommandFormatter.jsonSnippet` (JSON it made itself), `ChangeEvent.json` (JSON it encoded), `RogerMCP` diagnostics. Any other hit that parses text must use `TextFile`.

- [ ] **Step 2: No `\r` handling left in parsers**

Run: `cd /Users/jordi/git/roger/Roger && grep -rn '\\\\r' RogerKit Services/Library Services/MeetingRecording Services/Agents`
Expected: only the quoted-value escapes (`LibraryFrontmatterParser.unquote` `case "r"`, `TOON.quoted`) and the `TextFile` comments.

- [ ] **Step 3: AGENTS.md (local file, never `git add`)**

In `/Users/jordi/git/roger/AGENTS.md`, under "Key Services", add after the **RogerKit** bullet:

```markdown
- **TextFile** (RogerKit) - The one way to read a text file that is parsed: BOM, then UTF-8, then Windows-1252, line endings to LF. Never read Markdown, TOML or other text with `String(contentsOf:encoding: .utf8)`. JSON stays on `Data`. Files Roger writes are UTF-8 with LF.
- **LogEntrySaver / LibraryMigrationRun / MeetingFinalisationSteps** - The decisions behind saving a log entry, the first-launch migration and the finalisation file steps, as plain types with tests. `AppCoordinator` and `MeetingRecordingService` keep the UI and the audio side.
```

and change the **LibraryChangeRecorder** bullet to:

```markdown
- **LibraryChangeRecorder** - App side of the change log. Writers and the library window call `recordWritten(markdownURL:kind:root:)` with the root they wrote into, and `recordDeleted`; launch and a library folder change call `reconcile()`. The change log never creates a missing library root.
```

- [ ] **Step 4: Full test run and Release build**

Run:

```bash
cd /Users/jordi/git/roger/Roger
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -15
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Release build ARCHS=arm64 2>&1 | grep -E "warning:|error:|BUILD" | sort -u | tail -20
bash ../scripts/test-ingest-roger.sh
bash ../scripts/version-pins.sh
```

Expected: all tests pass, `** BUILD SUCCEEDED **` with no new warnings, the script tests pass and `version-pins.sh` passes (`MARKETING_VERSION` stays 0.25.0 in this plan, and its notes exist).

- [ ] **Step 5: Check the branch**

Run: `git -C /Users/jordi/git/roger log --oneline main..HEAD` and `git -C /Users/jordi/git/roger status --short`
Expected: one commit per task (28 plus the plan and spec commits), a clean tree, no `AGENTS.md` in the index, no commit message with AI attribution (`git -C /Users/jordi/git/roger log main..HEAD --format=%B | grep -i -e claude -e co-authored` prints nothing).

---

## Self-Review

**1. Spec coverage.**

| Spec item | Task |
|---|---|
| §1 `TextFile` (API, BOM, UTF-8, Windows-1252 with the five bytes, LF, `read` throws only file errors) | 1 |
| §1 users: `LibraryItemReader`, frontmatter parser callers, `ItemResolver.markdown` (`get_item`, `search`), `MeetingSessionScanner.transcriptReportsFailedAudio` | 2 |
| §1 users: `LibraryDocument.load/rename/saveBody` (mtime check stays, body normalized), `MeetingSegmentWriter` (existing segment, `sameContent`, `isDraft`), `LibraryActions.hasMeetingTranscript`, Codex TOML; `\r` on the H1 removed; `LibraryMarkdown` gets normalized text through the document | 3 |
| §1 tests for the five variants: decode, frontmatter, reader item, rename, save, retry compare, Codex TOML | 1, 2, 3 |
| #12 rename commits on click elsewhere, Esc cancels | 8 |
| #12 header and row update at once after rename or save | 8 |
| #12 saved entry stays listed and selected | 8 |
| #12 Unfinished disables search, date filter, sort | 7 |
| #12 Extra files reload on a change in the meeting folder | 9 |
| #12 Clean Up message after a retry started | 9 |
| #12 list keeps scroll position and focus, no rebuild | 10 (manual check, Ruling 12) |
| #12 meeting folder with a subfolder shows Extra files; subfolder row reveal-only | 9 |
| #12 title sort for logs uses the row text | 7 |
| #13 hidden `.md` ignored by updates | 4 |
| #13 meeting folders at any depth (extra folders included) | 4 |
| #13 missing root: no parent watch, "Library folder not found", recheck on activation and root change | 5 |
| #13 unfinished meetings count chunks as audio | 6 |
| #13 `scopeChangeStopsTheOldIndex` waits for a condition | 6 |
| #14 mic retry error names the system leftover | 11 (and 20) |
| #14 relaunch asks first, prompt and helper never together | 13 |
| #14 symlinked `.md` written through the link | 12 |
| #14 Finalise only for `isRogerSessionFolder` | 11 |
| #15 `library:` in the head, `ack(library:)` refusal text, unchanged without it, skill passes it | 14 |
| #10 log entry saving, first-launch migration, finalisation steps as tested types | 18, 19, 20 |
| #10 test host builds no `AppCoordinator`, never reads the real library | 21 |
| Finding 1 fsync | 16 |
| Finding 2 cached formatters and decoder | 17 |
| Finding 3 Agents tab off the main actor, consumers without a log | 22 |
| Finding 4 errors name tool and library, `status` with an unreadable log | 15 |
| Finding 5 TOML comment and quoted header | 23 |
| Finding 6 `recordWritten` takes the writer's root | 24 |
| Finding 7 one rule for a file found twice | 25 |
| Finding 8 `ingest-roger.sh` run count and last line | 26 |
| Finding 9 `release.yml` TeamIdentifier and timestamp | 26 |
| Finding 10 TOON key, patterns, session formatter, 512 px icon | 27 |
| Finding 11 missing tests | 28 |
| §3 behavior that stays (names, no deletes beyond the rules, events after writes) | 3, 12, 18, 20, 24 keep it; Task 20 `aFailedTranscriptWriteRecordsAndDeletesNothing`, Task 18 `aFailedWriteRecordsNothing` |
| Delivery order | Tasks follow steps 1 to 7 |

**2. Placeholder scan.** `grep -n -e TBD -e TODO -e "implement later" -e "fill in" -e "Similar to Task"` over this file finds nothing. Every code step has the code. Task 10's row height constant has a start value (52) and a measuring step.

**3. Type consistency.** Names used across tasks and where they are made: `TextFile` (1), `TextSample` (1), `LibraryIndex.libraryRootMissing/recheckRoot` (5), `LibraryIndex.refresh(paths:)` (8), `InMemoryLibraryIndex.watchedPaths/changeCount` (5, 9), `LibraryModel.libraryMissing/recheckLibraryRoot/didWrite/reloadCount` (5, 8, 9), `LibrarySidebarSelection.usesFilters` (7), `LibraryRenameState` (8), `MeetingExtraFiles.Kind.subfolder/isTrashable` (9), `LibraryActions.isRogerSessionFolder(...allowsSubfolders:)`, `extraFilesBusyMessage` (9), `LibraryActions.finalisable` (11), `MeetingRecordingError.trackAudioFailed(mic:system:setAside:)` (11), `RelaunchGate`, `AppRelauncher.terminateReply/helperScript/waitLoop` (13), `ChangeAnswer.render(library:)` (14), `FileIO` (16), `LogEntrySaver` (18), `LibraryMigrationRun` (19), `MeetingFinalisationSteps` (20), `AppLaunch`, `AppCoordinator.instancesCreated` (21), `AgentsController.live() async` (22), `HarnessRegistration.tomlTableName/tomlString` (23), `LibraryChangeRecorder.recordWritten(markdownURL:kind:root:)`, `onTranscriptWritten(transcript, root)` (24), `TOON.isPlainKey/looksLikeNumber` (27). Task 24 changes the closures that Tasks 18 and 20 introduce; it names both places.

**4. Review Focus.** Each of the five lines has its test in the owning task (named in the section). Other implied inputs checked: a UTF-8 BOM file (Task 1 to 3 variants), a lone surrogate or odd byte after a BOM (Task 1), `\r\r\n` (Task 1), a CRLF transcript with a failed-audio flag (Task 2), a directory named like an extra file (Task 9), Esc then focus loss (Task 8), the same library spelled `/var` and `/private/var` (Task 14), an `ack` of 0 in an empty library (Task 28), a `RESULT:` line quoted before the last line (Task 26).

**What was compile-checked and run.** In a scratch SwiftPM package (Swift 6.4, Xcode 27, platform macOS 15, Swift 6 language mode):
- All of `Roger/RogerKit` and `Roger/RogerKitTests` with every RogerKit change of this plan: 144 tests pass. Red before green was checked for Tasks 2, 6, 14, 15, 16 (compile), 27 and 28. Task 17's test passes before and after: it guards the shared formatters.
- An `AppCore` target with copies of the app files that do not need FluidAudio or the UI (all of `Services/Library` except `LibraryMarkdown`, `LibraryModel`, the `LibraryEmptyState` struct, `LibraryMigration`, `LogEntryWriter`, `LogAudioEncoder`, `TranscriptFrontmatter` with a stub for FluidAudio's `Repo`, the meeting writers, `MeetingExtraFiles`, `MeetingArchiveMerge`, `MeetingCheckpointStore`, `MeetingTranscriptMerger`, `MeetingSession`, `MeetingRecordingError`, `DictationPreset`, all of `Services/Agents`) plus the new types (`LogEntrySaver`, `LibraryMigrationRun`, `MeetingFinalisationSteps`, `LibraryRenameState`, `AppRelauncher`), with 23 `RogerTests` suites copied (`@testable import` renamed): 262 tests pass. Red before green was checked for Tasks 3, 4, 7, 9, 11, 12 and 25.
- Probes that compiled: the call shapes in `AppCoordinator` and `MeetingRecordingService` (closures into `LogEntrySaver`, `MeetingFinalisationSteps`, `LibraryMigrationRun`, `onTranscriptWritten` with a root), the `AgentsSettingsView` detached tasks, the `LibraryDetailView` rename pieces (`$rename.draft`, `onChange(of: titleFocused)`, `simultaneousGesture` on a `Group`), the `LibraryView` search binding, the `LibraryWindowController` activation observer and `Settings { if ... }`.
- `scripts/test-ingest-roger.sh` ran against the old script (six FAIL) and the new one (all ok).

Not compiled or run: the real edits in `AppCoordinator`, `MeetingRecordingService`, `RogerApp`, `LibraryDetailView`, `LibraryExtraFilesSection`, `LibraryListView`, `LibraryView`, `AgentsSettingsView`, `RecordingsSettingsView`, `LibrarySnapshotRunner` and `ToolCatalog` (needs the MCP package), the Xcode project changes (`TestSupport` in two targets), `RogerMCPEndToEndTests`, `BundledSkillTests`, `TestHostTests`, the `release.yml` check (a development signature has no secure timestamp, so it can only run in the release rehearsal) and Task 10's row height (manual check by design).

## Verified facts

Checked 2026-10-14 with Xcode 27.0 (Swift 6.4) on macOS 27:
- `String(data:encoding: .windowsCP1252)` returns nil for a buffer with 0x81, 0x8D, 0x8F, 0x90 or 0x9D; 0x80 gives U+20AC.
- `String(data:encoding: .utf8)` drops a UTF-8 BOM; `.utf16LittleEndian` keeps U+FEFF; `.utf16` drops it.
- `"a\r\nb".split(separator: "\n").count == 1`: `"\r\n"` is one `Character`. This is why CRLF frontmatter was not found (#11).
- `FileManager.attributesOfItem(atPath:)` on a symlink reports the link's own modification date (Task 12's `targetChangedBehindALinkIsDetected` fails without the fix).
- A `static let` of `ISO8601DateFormatter` is a Swift 6 error ("not concurrency-safe"); `JSONDecoder` and `DateFormatter` are `Sendable`.
- A synchronous actor method does not win over an `async` default in a protocol extension when the call site has the concrete actor type: the default runs. The actor's methods for new protocol requirements are declared `async` (Tasks 5 and 8).
- `ack` with `upTo: 0` created `.roger/consumers/.lock` before Task 28.
- `.id(model.results.isEmpty)` came with commit b6c4d4a ("Rows added to the empty list kept the first row height, so only the title showed until the next layout"); the focus fix fb80523 followed because the rebuilt list lost the focus.
