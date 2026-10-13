# Library Window (Roger 0.24.0 "Library computer access") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A library window lists every log entry, meeting and file transcript in Roger's library, with search, filters, sorting, a preview with rename and edit, and hand-off actions (drag, copy path, open, reveal, Trash), and meeting retries stop losing edited segment files and explain their extra files (#6, #8, #9).

**Architecture:** Pure, tested types do all the work: `LibraryFrontmatterParser` and `LibraryItemReader` turn files into `LibraryItem`s, `LibraryQuery` filters and sorts them, and the `InMemoryLibraryIndex` actor (behind the `LibraryIndex` protocol) keeps them current from an `FSEventStream`. A `LibraryWindowController` hosts the SwiftUI `LibraryView` in an `NSWindow` and switches the activation policy. Thin SwiftUI views read a `@MainActor` `LibraryModel`. Meeting finalisation gets one shared move-aside helper (#8) and a scanner for extra files that feeds `sources`, the error text and the detail pane (#9).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI and AppKit (`NSWindow`, `NSHostingController`, `NSWorkspace`), CoreServices FSEvents, KeyboardShortcuts, XcodeGen, Swift Testing, macOS 15+.

**Spec:** `docs/superpowers/specs/2026-10-13-log-entries-and-library-design.md`. Phase 2 is sections 3 (app shell), 4 (library UI), 5 (index), the phase 2 line in section 8 and all of section 9 (carried-over items, #8, #9). Issues: #6 (library window), #8 (retry overwrites edited segment files), #9 (extra files after a retry).

## Global Constraints

- Work on branch `feat/library-window` in `/Users/jordi/git/roger` (already checked out).
- macOS 15.0 deployment target, Swift 6 strict concurrency with no new warnings, `@MainActor` for `@Observable` types SwiftUI observes.
- Logging via `os.Logger` with subsystem `com.jordiboehme.roger`.
- Commits: plain conventional-commit messages. NEVER add `Co-Authored-By`, "Generated with Claude Code" or any AI attribution.
- User-facing strings (UI text, alerts, README): no em-dash "—" or en-dash "–" (use "-"), no Oxford comma ("A, B and C"), short plain sentences. Author name is "Jordi Böhme".
- Debug builds: `cd /Users/jordi/git/roger/Roger && xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | tail -20`. Never pass `CONFIGURATION_BUILD_DIR` for Debug.
- Tests: `cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -40`. Add `-only-testing:RogerTests/<SuiteName>` to run one suite.
- New files need the project regenerated. After every `xcodegen generate`: run `git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements` (xcodegen empties it), check `git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements` prints nothing, and commit the regenerated `Roger/Roger.xcodeproj` (it is tracked, including `xcshareddata/xcschemes/Roger.xcscheme`). New folders `Roger/Services/Library/` and `Roger/UI/Library/` are picked up automatically because `project.yml` lists whole folders.
- Tests run inside the real Roger.app (same bundle ID, so `UserDefaults.standard` is the developer's live settings). Tests must NEVER construct `AppState` or `AppCoordinator`, never write to `UserDefaults.standard`, never touch `~/Documents`, never call `ExternalTranscriptRegistry.standard` and never move anything to the real Trash. Use `TempFolder.make()` / `TempFolder.remove(_:)` (in `Roger/RogerTests/TempFolder.swift`) with injected roots, dates and closures.
- `AGENTS.md` is in `.gitignore`. Edit it in place, never `git add` it.
- Do not bump `MARKETING_VERSION` and do not write release notes. The release is a separate step.
- Meeting folders hold the user's only copy of audio and transcripts. Library and meeting code never deletes or overwrites them: user-triggered removal goes through `FileManager.trashItem` (meetings only after a confirmation), and move-aside picks a free `<stem>.previous[ N].<ext>` name and never replaces an existing file. The only `removeItem` calls that stay are the existing ones for draft segments, CAF chunks and temp files.
- File names in the library never change. Rename edits only the frontmatter `title` and the first H1.
- Item kinds come from the tags Roger writes: `[log]` is a log entry, `[meeting, transcript]` is a meeting (the item is the session, its file is `transcript.md`), `[transcript]` is a file transcript, `[meeting, segment]` is never listed. A session folder without `transcript.md` is an unfinished meeting.
- The library window is an `NSWindow` hosting `NSHostingController(rootView: LibraryView)`, owned by `LibraryWindowController`. Not a SwiftUI `Window` scene (`openWindow` is not reachable from the AppKit popover). One instance; reopening brings it to the front; frame saved with `setFrameAutosaveName("RogerLibraryWindow")`.
- Activation policy: `NSApp.setActivationPolicy(.regular)` when the library opens, `.accessory` when it closes. `LSUIElement` stays `true`. Settings and onboarding never change the policy. The `Settings` scene gives "Roger > Settings…" with Cmd-, automatically.
- The index is an in-memory actor behind `protocol LibraryIndex: Sendable { func items() async -> [LibraryItem]; func search(_ query: LibraryQuery) async -> [LibraryItem]; var changes: AsyncStream<Void> { get } }`. It is built on first use and kept current by an `FSEventStream` with 0.5 s latency. The detail pane reads the file from disk each time. Edit mode checks the modification date before saving.
- Paths the index compares go through `LibraryPath.canonical(_:)` (`realpath` of the nearest existing ancestor). Never use `resolvingSymlinksInPath()` for this: it turns `/private/var` into `/var`, while FSEvents reports `/private/var`.
- Keep SwiftUI views thin. Parsing, querying, grouping, formatting, editing, action planning and extra-file detection live in plain types with tests.

## Review Focus

1. Moving items to the Trash must never take more than the selected entries: not the library root, a kind or month folder, an extra scan folder, the source media of a file transcript, or the folder of a meeting that is being recorded or finalised. (Task 9: `trashPlan` tests.)
2. A file that changed on disk or was deleted while you edit it must never be overwritten silently or recreated, and a rename made in the meantime must survive "Overwrite". (Task 5: `saveBody` tests.)
3. After a meeting retry, `transcript.previous*.md` and segment files (including `*.previous.md`) must never show up as extra library items. (Task 3: `retryLeftoversAreNotItems`.)
4. An entry written into a month folder that did not exist when the index was built must appear without reopening the window. (Task 3: `applyPicksUpNewMonthFolder`; Task 4: `watcherKeepsIndexCurrent`.)
5. The same file reached as `/var/...` and as `/private/var/...` must be one item, and "show in library" must find it. (Task 3: `symlinkedSpellingsAreOneItem`; Task 6: `pendingSelectionWaitsForItem`.)

## Rulings

Where the spec is silent or a literal reading would hurt, these rulings apply. Reviewers: treat them as part of the spec.

1. Unfinished meetings (session folders with audio but no transcript, or a transcript with failed audio and kept chunks) also appear in the Meetings list, marked "Unfinished". The sidebar "Unfinished" entry still shows exactly `AppCoordinator.pendingMeetingSessions` (spec 9). Without this, a dismissed unfinished session would vanish from the library.
2. Day headers appear only with the date sorts. Title and duration sorts show one flat list with the date in each row, so the chosen order is kept.
3. Drag: SwiftUI on macOS 15 has no multi-item `List` drag API (`dragContainer` needs macOS 26), so a drag carries the dragged row's file. Copy Path is the hand-off for several files. Only a manual check can confirm what a multi-row drag does.
4. Clean Up never edits `transcript.md`, so its `sources` may still name extra audio that is now in the Trash. Clean Up is hidden while the meeting is unfinished (a retry may still need the files).
5. #8: every segment that is not `status: draft` is moved aside before a rewrite, not only `stable` ones (a hand-edited file without frontmatter counts as the user's copy). The same applies when finalisation would delete a segment whose range became empty.
6. The `media` source counts as audio: "Open Audio" on a file transcript opens its source file.
7. While a body is edited, the list is locked and the detail pane keeps showing the edited item, so unsaved text is never dropped.
8. Logs and file transcripts go to the Trash without a question (they can be put back); only meeting folders ask first, as the spec says.
9. Cmd-Backspace works only while the list has focus, so it never fires in the search field or the editor.
10. A meeting whose session folder is, or contains, the library root, a kind folder or an extra scan folder is skipped, not partly trashed. A meeting-tagged file outside a session folder trashes only that file.
11. Copy Folder Path on a transcript written next to its source gives that source's folder.

## File Map

| File | Task | Responsibility |
|---|---|---|
| `Roger/Models/LibraryItem.swift` | 1 | `LibraryItemKind`, `LibraryItem` |
| `Roger/Services/Library/LibraryFrontmatterParser.swift` | 1 | Split and parse the frontmatter Roger writes |
| `Roger/Services/Library/LibraryItemReader.swift` | 1 | File or session folder to `LibraryItem` |
| `Roger/Services/Library/LibraryQuery.swift` | 2 | Sort, date filter, search, `LibraryQuery.apply` |
| `Roger/Services/Library/LibraryDayGrouping.swift` | 2 | Day sections, `LibraryFormat` (durations, dates, metadata line) |
| `Roger/Services/Library/LibraryPath.swift` | 3 | Canonical paths, containment |
| `Roger/Services/Library/LibraryIndex.swift` | 3, 4 | Protocol, scope, scan units, `InMemoryLibraryIndex` |
| `Roger/Services/Library/LibraryFolderWatcher.swift` | 4 | FSEventStream wrapper |
| `Roger/Services/Library/LibraryIndexStore.swift` | 4 | One live index per scope |
| `Roger/Services/Library/LibraryDocument.swift` | 5 | Load, rename, save body with conflict check, `canEdit` |
| `Roger/App/LibraryWindowController.swift` | 6 | NSWindow, activation policy |
| `Roger/UI/Library/LibraryModel.swift` | 6 | `@MainActor` view state over a `LibraryIndex` |
| `Roger/UI/Library/LibraryView.swift` | 6, 7, 8 | Three-column split view |
| `Roger/UI/Library/LibrarySidebarView.swift` | 6 | Kinds with counts, Unfinished |
| `Roger/UI/Library/LibraryUnfinishedListView.swift` | 6 | Pending sessions with Finalise and Dismiss |
| `Roger/UI/Library/LibraryListView.swift` | 7, 9 | Day-grouped rows, toolbar, actions |
| `Roger/UI/Library/LibraryToolbar.swift` | 7 | Date filter and sort menus |
| `Roger/UI/Library/LibraryEmptyState.swift` | 7 | Empty-state texts (pure) and view |
| `Roger/Services/Library/LibraryMarkdown.swift` | 8 | Markdown blocks, highlight ranges |
| `Roger/UI/Library/LibraryDetailView.swift` | 8, 11 | Header, preview, rename, edit, extra files |
| `Roger/Services/Library/LibraryActions.swift` | 9 | Paths, folders, Trash plan, Trash |
| `Roger/UI/Library/LibraryCommands.swift` | 9 | AppKit side of the actions |
| `Roger/Services/MeetingRecording/MeetingArchiveMerge.swift` | 10 | Shared `moveAside` helper |
| `Roger/Services/MeetingRecording/MeetingSegmentWriter.swift` | 10 | Never lose an edited segment |
| `Roger/Services/MeetingRecording/MeetingExtraFiles.swift` | 11 | Detect extra files, `sources` ids |
| `Roger/UI/Library/LibraryExtraFilesSection.swift` | 11 | Extra files in the meeting detail |

---

### Task 1: LibraryItem, frontmatter parser and item reader

**Files:**
- Create: `Roger/Models/LibraryItem.swift`
- Create: `Roger/Services/Library/LibraryFrontmatterParser.swift`
- Create: `Roger/Services/Library/LibraryItemReader.swift`
- Modify: `Roger/Services/MeetingRecording/MeetingCheckpointStore.swift` (`markersURL(in:)` becomes `nonisolated`)
- Test: `Roger/RogerTests/LibraryFrontmatterParserTests.swift`
- Test: `Roger/RogerTests/LibraryItemReaderTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes (existing): `TranscriptFrontmatter` (`init(title:description:resource:tags:generatedAt:sourceDate:temporalConfidence:sources:status:)`, `render()`, `quoted(_:)`, `timestamp(_:)`), `LogEntry`, `LogEntryWriter.content(for:audioFileName:generatedAt:)`, `LogEntryWriter.title(for:)`, `MeetingTranscriptWriter.write(paragraphs:metadata:markers:)`, `MeetingTranscriptWriter.displayDate(_:)`, `MeetingSegmentWriter.write(paragraphs:sessionStartedAt:chunkStart:chunkEnd:folder:provisional:)`, `MediaTranscriptFormatter.content(...)`, `MeetingSessionScanner.isUnfinished(_:)`, `LibraryMigration.sessionDate(for:)`, `MeetingCheckpointFile`, `MeetingCheckpointStore.markersURL(in:)`.
- Produces:
  - `enum LibraryItemKind: String, CaseIterable, Sendable, Hashable { case log, meeting, transcript; var displayName: String; var pluralName: String; var systemImage: String }`
  - `struct LibraryItem: Identifiable, Hashable, Sendable` with `var url, folderURL: URL; var kind: LibraryItemKind; var title: String; var date: Date; var durationSeconds: Int?; var language: String?; var preset: String?; var speakerCount: Int?; var screenshotCount: Int; var audioFiles: [URL]; var firstLine: String; var searchText: String; var isUnfinished: Bool; var id: String { url.path }; var hasAudio: Bool; var hasMarkdown: Bool`
  - `struct LibraryFrontmatter: Equatable, Sendable { var scalars: [String: String]; var tags: [String]; var sources: [Source]; struct Source: Equatable, Sendable { let id: String; let resource: String } }`
  - `enum LibraryFrontmatterParser { static func split(_ text: String) -> (frontmatter: Substring?, body: Substring); static func parse(_ text: String) -> LibraryFrontmatter?; static func unquote(_ raw: String) -> String; static func inlineMap(_ raw: String) -> [String: String] }`
  - `enum LibraryItemReader { static func item(markdownAt url: URL, fallbackKind: LibraryItemKind, folder: URL? = nil) -> LibraryItem?; static func meetingItem(sessionFolder: URL) -> LibraryItem?; static func firstLine(ofBody: String) -> String }`

- [ ] **Step 1: Write the failing parser tests**

`Roger/RogerTests/LibraryFrontmatterParserTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryFrontmatterParserTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func splitIsByteExact() {
        let text = "---\ntype: source\n---\n\n# H\n\nBody\n"
        let parts = LibraryFrontmatterParser.split(text)
        #expect(parts.frontmatter == "---\ntype: source\n---\n")
        #expect(parts.body == "\n# H\n\nBody\n")
        #expect(String(parts.frontmatter ?? "") + String(parts.body) == text)
    }

    @Test func textWithoutFrontmatterIsAllBody() {
        let parts = LibraryFrontmatterParser.split("# Just a heading\n")
        #expect(parts.frontmatter == nil)
        #expect(parts.body == "# Just a heading\n")
        #expect(LibraryFrontmatterParser.parse("# Just a heading\n") == nil)
    }

    @Test func unclosedFrontmatterIsAllBody() {
        let text = "---\ntitle: x\nno end here\n"
        #expect(LibraryFrontmatterParser.split(text).frontmatter == nil)
        #expect(LibraryFrontmatterParser.parse(text) == nil)
    }

    @Test func emptyFrontmatterParses() {
        #expect(LibraryFrontmatterParser.parse("---\n---\nBody") == LibraryFrontmatter())
    }

    @Test func readsLogEntry() throws {
        let entry = LogEntry(
            text: "Called the supplier about the delayed shipment",
            startedAt: date,
            endedAt: date.addingTimeInterval(33),
            presetName: "Log",
            language: "de"
        )
        let text = LogEntryWriter.content(for: entry, audioFileName: "2026-10-13 14-32-05.m4a", generatedAt: date)
        let fm = try #require(LibraryFrontmatterParser.parse(text))
        #expect(fm.tags == ["log"])
        #expect(fm.scalars["title"] == LogEntryWriter.title(for: entry))
        #expect(fm.scalars["duration_seconds"] == "33")
        #expect(fm.scalars["preset"] == "Log")
        #expect(fm.scalars["language"] == "de")
        #expect(fm.scalars["status"] == "stable")
        #expect(fm.scalars["started_at"] == TranscriptFrontmatter.timestamp(date))
        #expect(fm.scalars["generated"]?.hasPrefix("{ by: roger/") == true)
        #expect(fm.sources == [.init(id: "audio", resource: "2026-10-13 14-32-05.m4a")])
    }

    @Test func quotedValuesRoundTrip() throws {
        let title = "A \"b\": c\nd\t#e \\ f\u{2028}g"
        let text = TranscriptFrontmatter(
            title: title,
            description: "x",
            tags: ["transcript"],
            sourceDate: date,
            temporalConfidence: .explicit,
            status: "stable"
        ).render()
        let fm = try #require(LibraryFrontmatterParser.parse(text))
        #expect(fm.scalars["title"] == title)
    }

    @Test func readsMediaSource() throws {
        let source = URL(fileURLWithPath: "/tmp/RogerLib/talk.mp4")
        let text = MediaTranscriptFormatter.content(
            source: source,
            destination: URL(fileURLWithPath: "/tmp/RogerLib/talk.mp4.md"),
            recording: .init(startedAt: date, confidence: .explicit, durationSeconds: 90, fileModifiedAt: date),
            paragraphs: [],
            plainText: "Hello",
            language: nil,
            diarized: false,
            diarizationFailed: false
        )
        let fm = try #require(LibraryFrontmatterParser.parse(text))
        #expect(fm.tags == ["transcript"])
        #expect(fm.sources == [.init(id: "media", resource: "talk.mp4")])
        #expect(fm.scalars["resource"] == "talk.mp4")
    }

    @Test func readsBlockListTags() {
        let fm = LibraryFrontmatterParser.parse("---\ntags:\n- meeting\n- transcript\n---\n")
        #expect(fm?.tags == ["meeting", "transcript"])
    }

    @Test func inlineMapKeepsCommasAndColonsInsideQuotes() {
        let map = LibraryFrontmatterParser.inlineMap("{ id: audio, resource: \"a, b: c.m4a\", last_modified: 2026-10-13T14:32:41+02:00 }")
        #expect(map == ["id": "audio", "resource": "a, b: c.m4a", "last_modified": "2026-10-13T14:32:41+02:00"])
    }
}
```

- [ ] **Step 2: Write the failing reader tests**

`Roger/RogerTests/LibraryItemReaderTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryItemReaderTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func logEntry() -> LogEntry {
        LogEntry(
            text: "Called the supplier about the delayed shipment",
            startedAt: date,
            endedAt: date.addingTimeInterval(33),
            presetName: "Log",
            language: "de"
        )
    }

    private func metadata(_ folder: URL) -> MeetingTranscriptWriter.Metadata {
        MeetingTranscriptWriter.Metadata(
            session: MeetingSession(id: UUID(), folder: folder, startedAt: date),
            durationSeconds: 120,
            speakerCount: 2,
            language: "en",
            micPresent: true,
            systemPresent: true,
            audioKept: true,
            diarized: false,
            diarizationFailed: false
        )
    }

    @Test func logEntryItem() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("2026-10-13 14-32-05.md")
        let audio = root.appendingPathComponent("2026-10-13 14-32-05.m4a")
        try LogEntryWriter.content(for: logEntry(), audioFileName: audio.lastPathComponent, generatedAt: date)
            .write(to: md, atomically: true, encoding: .utf8)
        try Data().write(to: audio)

        let item = try #require(LibraryItemReader.item(markdownAt: md, fallbackKind: .transcript))
        #expect(item.kind == .log)
        #expect(item.title == LogEntryWriter.title(for: logEntry()))
        #expect(item.date == date)
        #expect(item.durationSeconds == 33)
        #expect(item.preset == "Log")
        #expect(item.language == "de")
        #expect(item.audioFiles.map(\.lastPathComponent) == [audio.lastPathComponent])
        #expect(item.firstLine == "Called the supplier about the delayed shipment")
        #expect(item.searchText.contains("supplier"))
        #expect(item.folderURL == root)
        #expect(item.hasMarkdown)
        #expect(!item.isUnfinished)
    }

    @Test func audioIsListedOnlyWhenTheFileExists() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("a.md")
        try LogEntryWriter.content(for: logEntry(), audioFileName: "a.m4a", generatedAt: date)
            .write(to: md, atomically: true, encoding: .utf8)
        #expect(LibraryItemReader.item(markdownAt: md, fallbackKind: .log)?.hasAudio == false)
    }

    @Test func segmentFilesAreNotItems() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let url = try #require(try MeetingSegmentWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: "Hello")],
            sessionStartedAt: date,
            chunkStart: date,
            chunkEnd: date.addingTimeInterval(60),
            folder: root,
            provisional: false
        ))
        #expect(LibraryItemReader.item(markdownAt: url, fallbackKind: .meeting) == nil)
    }

    @Test func meetingItemFromSessionFolder() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        _ = try MeetingTranscriptWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: "Welcome everyone")],
            metadata: metadata(root)
        )
        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: root))
        #expect(item.kind == .meeting)
        #expect(item.url.lastPathComponent == "transcript.md")
        #expect(item.folderURL == root)
        #expect(item.speakerCount == 2)
        #expect(item.durationSeconds == 120)
        #expect(item.title.hasPrefix("Meeting "))
        #expect(item.firstLine == "Welcome everyone")
        #expect(!item.isUnfinished)
    }

    @Test func unfinishedSessionWithoutTranscript() throws {
        let parent = try TempFolder.make()
        defer { TempFolder.remove(parent) }
        let folder = parent.appendingPathComponent("2026-10-13 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("mic-001.caf"))

        let item = try #require(LibraryItemReader.meetingItem(sessionFolder: folder))
        #expect(item.isUnfinished)
        #expect(item.url == folder)
        #expect(!item.hasMarkdown)
        #expect(item.date == LibraryMigration.sessionDate(for: folder))
        #expect(item.title == "Unfinished meeting 2026-10-13 09:00")
    }

    @Test func sessionWithoutAudioOrTranscriptIsNoItem() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("markers.json"))
        #expect(LibraryItemReader.meetingItem(sessionFolder: folder) == nil)
    }

    @Test func brokenFileFallsBackToFileNameAndDates() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("notes.md")
        try Data("---\ntitle: \"unclosed\nstill no end".utf8).write(to: md)
        let item = try #require(LibraryItemReader.item(markdownAt: md, fallbackKind: .transcript))
        #expect(item.kind == .transcript)
        #expect(item.title == "notes")
        #expect(item.date != .distantPast)
    }

    @Test func unreadableTextStillGivesAnItem() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let md = root.appendingPathComponent("binary.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: md)
        let item = try #require(LibraryItemReader.item(markdownAt: md, fallbackKind: .log))
        #expect(item.title == "binary")
        #expect(item.kind == .log)
    }

    @Test func firstLineSkipsHeadingsImagesAndSpeakerHeaders() {
        let body = "\n# Meeting\n\n![Screenshot](a.png)\n\n**Me** [00:00:01 · 2026-10-13 09:00:01]\nHello **there**\n"
        #expect(LibraryItemReader.firstLine(ofBody: body) == "Hello there")
    }
}
```

- [ ] **Step 3: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryFrontmatterParserTests -only-testing:RogerTests/LibraryItemReaderTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryFrontmatterParser' in scope" (and `LibraryItemReader`, `LibraryFrontmatter`).

- [ ] **Step 4: Write `LibraryItem`**

`Roger/Models/LibraryItem.swift`:

```swift
import Foundation

/// What a library entry is. Decided by the tags Roger writes (see
/// `LibraryItemReader`).
enum LibraryItemKind: String, CaseIterable, Sendable, Hashable {
    case log
    case meeting
    case transcript

    var displayName: String {
        switch self {
        case .log: return "Log"
        case .meeting: return "Meeting"
        case .transcript: return "Transcript"
        }
    }

    var pluralName: String {
        switch self {
        case .log: return "Logs"
        case .meeting: return "Meetings"
        case .transcript: return "Transcripts"
        }
    }

    var systemImage: String {
        switch self {
        case .log: return "book.closed"
        case .meeting: return "person.2"
        case .transcript: return "doc.text"
        }
    }
}

/// One entry in the library window: a log entry, a meeting or a file
/// transcript, read from its Markdown file.
struct LibraryItem: Identifiable, Hashable, Sendable {
    /// The Markdown file (meetings: `transcript.md`). For an unfinished
    /// meeting without a transcript, the session folder.
    var url: URL
    /// Meetings: the session folder. Logs and transcripts: the folder that
    /// holds the file.
    var folderURL: URL
    var kind: LibraryItemKind
    var title: String
    /// Recording start (`started_at`), else `source_date`, else file dates.
    var date: Date
    var durationSeconds: Int?
    var language: String?
    var preset: String?
    var speakerCount: Int?
    var screenshotCount: Int
    /// Existing files from `sources` with id `audio`, `mic`, `system` or `media`.
    var audioFiles: [URL]
    var firstLine: String
    /// Lowercased title and body, for search.
    var searchText: String
    /// The session still has audio to transcribe (see `MeetingSessionScanner.isUnfinished`).
    var isUnfinished: Bool

    var id: String { url.path }
    var hasAudio: Bool { !audioFiles.isEmpty }
    var hasMarkdown: Bool { url.pathExtension.lowercased() == "md" }
}
```

- [ ] **Step 5: Write the parser**

`Roger/Services/Library/LibraryFrontmatterParser.swift`:

```swift
import Foundation

/// The parts of a Roger Markdown file's frontmatter the library needs.
struct LibraryFrontmatter: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        let id: String
        let resource: String
    }

    /// Top-level `key: value` lines with the value unquoted. Inline maps
    /// such as `generated` keep their raw `{ ... }` text.
    var scalars: [String: String] = [:]
    var tags: [String] = []
    var sources: [Source] = []
}

/// Reads the frontmatter `TranscriptFrontmatter` writes: top-level scalars
/// (plain, double-quoted or single-quoted), `tags` as `[a, b]` or a block
/// list, and `sources` as a block list of inline maps. Not a general YAML
/// parser.
enum LibraryFrontmatterParser {
    /// Splits `text` into the frontmatter block (the opening `---` line up to
    /// and including the closing `---` line) and the rest, so that
    /// `frontmatter + body == text`. No frontmatter when the text does not
    /// start with `---\n` or the block is never closed.
    static func split(_ text: String) -> (frontmatter: Substring?, body: Substring) {
        guard text.hasPrefix("---\n") else { return (nil, text[...]) }
        let searchStart = text.index(text.startIndex, offsetBy: 3)
        if let close = text.range(of: "\n---\n", range: searchStart..<text.endIndex) {
            return (text[..<close.upperBound], text[close.upperBound...])
        }
        if text.hasSuffix("\n---") {
            return (text[...], text[text.endIndex...])
        }
        return (nil, text[...])
    }

    static func parse(_ text: String) -> LibraryFrontmatter? {
        guard let block = split(text).frontmatter else { return nil }
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeFirst()
        if lines.last == "" { lines.removeLast() }
        if lines.last == "---" { lines.removeLast() }

        var result = LibraryFrontmatter()
        var listKey: String?
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("-") {
                let entry = line.trimmingCharacters(in: .whitespaces)
                guard entry.hasPrefix("-"), let key = listKey else { continue }
                let value = entry.dropFirst().trimmingCharacters(in: .whitespaces)
                if key == "tags" {
                    result.tags.append(unquote(value))
                } else if key == "sources" {
                    let map = inlineMap(value)
                    if let id = map["id"], let resource = map["resource"] {
                        result.sources.append(.init(id: id, resource: resource))
                    }
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                listKey = nil
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            listKey = value.isEmpty ? key : nil
            if key == "tags", value.hasPrefix("[") {
                result.tags = flowList(value)
            } else if !value.isEmpty {
                result.scalars[key] = value.hasPrefix("{") ? value : unquote(value)
            }
        }
        return result
    }

    /// Undoes `TranscriptFrontmatter.quoted`: `\"`, `\\`, `\n`, `\r`, `\t`
    /// and `\uXXXX`. Single-quoted values lose their quotes (`''` is `'`).
    /// Anything else is returned trimmed.
    static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var out = ""
        var scalars = String(value.dropFirst().dropLast()).unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\\" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            guard let next = scalars.next() else {
                out.append("\\")
                break
            }
            switch next {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    if let digit = scalars.next() { hex.unicodeScalars.append(digit) }
                }
                if let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) {
                    out.unicodeScalars.append(decoded)
                } else {
                    out += "\\u" + hex
                }
            default:
                out.append("\\")
                out.unicodeScalars.append(next)
            }
        }
        return out
    }

    /// `{ id: audio, resource: "a.m4a" }` as a dictionary with unquoted
    /// values. Only the first `:` of each entry separates key and value.
    static func inlineMap(_ raw: String) -> [String: String] {
        var inner = raw.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("{") { inner.removeFirst() }
        if inner.hasSuffix("}") { inner.removeLast() }
        var map: [String: String] = [:]
        for part in splitOutsideQuotes(inner, separator: ",") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces)
            let value = String(part[part.index(after: colon)...])
            if !key.isEmpty { map[key] = unquote(value) }
        }
        return map
    }

    /// `[a, "b, c"]` as `["a", "b, c"]`.
    private static func flowList(_ raw: String) -> [String] {
        var inner = raw.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        return splitOutsideQuotes(inner, separator: ",").map(unquote).filter { !$0.isEmpty }
    }

    private static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == separator && !inQuotes {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
```

- [ ] **Step 6: Write the reader**

`Roger/Services/Library/LibraryItemReader.swift`:

```swift
import Foundation

/// Builds `LibraryItem`s from files on disk. Never throws: a file that
/// cannot be read or parsed still becomes an item, named after the file and
/// dated by the file system, so it stays visible in the library.
enum LibraryItemReader {
    static let maxFirstLineLength = 200
    /// `sources` ids whose files count as the item's audio ("Open Audio").
    /// `media` is the source file of a file transcript.
    static let audioSourceIDs: Set<String> = ["audio", "mic", "system", "media"]

    /// One Markdown file. Nil only for meeting segment files
    /// (`[meeting, segment]`), which belong to their meeting. `fallbackKind`
    /// applies when the tags do not say. `folder` overrides the item's
    /// folder (meetings: the session folder).
    static func item(markdownAt url: URL, fallbackKind: LibraryItemKind, folder: URL? = nil) -> LibraryItem? {
        let text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let front = LibraryFrontmatterParser.parse(text)
        let tags = Set(front?.tags ?? [])
        if tags.contains("meeting") && tags.contains("segment") { return nil }

        let kind: LibraryItemKind
        if tags.contains("log") {
            kind = .log
        } else if tags.contains("meeting") && tags.contains("transcript") {
            kind = .meeting
        } else if tags.contains("transcript") {
            kind = .transcript
        } else {
            kind = fallbackKind
        }

        let body = String(LibraryFrontmatterParser.split(text).body)
        let scalars = front?.scalars ?? [:]
        let baseFolder = url.deletingLastPathComponent()
        let title = nonEmpty(scalars["title"])
            ?? firstHeading(in: body)
            ?? url.deletingPathExtension().lastPathComponent
        let audio = (front?.sources ?? [])
            .filter { audioSourceIDs.contains($0.id) }
            .map { resolve($0.resource, relativeTo: baseFolder) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        return LibraryItem(
            url: url,
            folderURL: folder ?? baseFolder,
            kind: kind,
            title: title,
            date: recordingDate(scalars) ?? fileDate(url) ?? .distantPast,
            durationSeconds: scalars["duration_seconds"].flatMap { Int($0) },
            language: nonEmpty(scalars["language"]),
            preset: nonEmpty(scalars["preset"]),
            speakerCount: scalars["speaker_count"].flatMap { Int($0) },
            screenshotCount: scalars["screenshot_count"].flatMap { Int($0) } ?? 0,
            audioFiles: audio,
            firstLine: firstLine(ofBody: body),
            searchText: (title + "\n" + body).lowercased(),
            isUnfinished: false
        )
    }

    /// The item for a meeting session folder: its `transcript.md`, or an
    /// "unfinished" item for a folder that still has audio but no
    /// transcript. Nil for a folder with neither.
    static func meetingItem(sessionFolder folder: URL) -> LibraryItem? {
        let fm = FileManager.default
        let unfinished = MeetingSessionScanner.isUnfinished(folder)
        let transcript = folder.appendingPathComponent("transcript.md")
        if fm.fileExists(atPath: transcript.path) {
            guard var item = Self.item(markdownAt: transcript, fallbackKind: .meeting, folder: folder) else { return nil }
            item.kind = .meeting
            item.isUnfinished = unfinished
            return item
        }
        guard unfinished else { return nil }
        let markers = loadMarkers(folder)
        let started = markers?.sessionStartedAt
            ?? LibraryMigration.sessionDate(for: folder)
            ?? fileDate(folder)
            ?? .distantPast
        let title = "Unfinished meeting \(MeetingTranscriptWriter.displayDate(started))"
        let audio = ["mic.m4a", "system.m4a"]
            .map { folder.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        return LibraryItem(
            url: folder,
            folderURL: folder,
            kind: .meeting,
            title: title,
            date: started,
            durationSeconds: nil,
            language: nil,
            preset: nil,
            speakerCount: nil,
            screenshotCount: markers?.markers.count ?? 0,
            audioFiles: audio,
            firstLine: "Not transcribed yet.",
            searchText: title.lowercased(),
            isUnfinished: true
        )
    }

    /// First line of text worth showing in a list row: skips headings,
    /// images and meeting speaker headers, drops `**`.
    static func firstLine(ofBody body: String) -> String {
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("![") || isSpeakerHeader(line) { continue }
            return String(line.replacingOccurrences(of: "**", with: "").prefix(maxFirstLineLength))
        }
        return ""
    }

    /// `**Speaker** [00:01:02]` or `**Speaker** [00:01:02 · 2026-10-13 09:01:02]`.
    private static func isSpeakerHeader(_ line: String) -> Bool {
        line.hasPrefix("**") && line.hasSuffix("]") && line.contains("** [")
    }

    private static func firstHeading(in body: String) -> String? {
        for raw in body.split(separator: "\n") where raw.hasPrefix("# ") {
            return nonEmpty(String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func recordingDate(_ scalars: [String: String]) -> Date? {
        if let raw = scalars["started_at"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
        }
        if let raw = scalars["source_date"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: raw)
        }
        return nil
    }

    private static func fileDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.creationDate] as? Date) ?? (attributes?[.modificationDate] as? Date)
    }

    /// `resource` is relative to the Markdown file's folder unless absolute.
    private static func resolve(_ resource: String, relativeTo folder: URL) -> URL {
        if resource.hasPrefix("/") { return URL(fileURLWithPath: resource) }
        return folder.appendingPathComponent(resource).standardizedFileURL
    }

    /// `markers.json`, decoded here because `MeetingCheckpointStore.load` is
    /// main-actor isolated and the index reads off the main actor.
    private static func loadMarkers(_ folder: URL) -> MeetingCheckpointFile? {
        guard let data = try? Data(contentsOf: MeetingCheckpointStore.markersURL(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingCheckpointFile.self, from: data)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
```

`MeetingCheckpointStore` is a `@MainActor` class, so its static `markersURL(in:)` is main-actor isolated and cannot be called from the reader (the index calls it off the main actor). In `Roger/Services/MeetingRecording/MeetingCheckpointStore.swift`, change `static func markersURL(in folder: URL) -> URL` to `nonisolated static func markersURL(in folder: URL) -> URL`. It only builds a URL, like the already `nonisolated` `stem(for:)`.

- [ ] **Step 7: Regenerate and run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryFrontmatterParserTests -only-testing:RogerTests/LibraryItemReaderTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 18 tests passed.

- [ ] **Step 8: Run the whole suite and commit**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Models/LibraryItem.swift Roger/Services/Library Roger/Services/MeetingRecording/MeetingCheckpointStore.swift Roger/RogerTests/LibraryFrontmatterParserTests.swift Roger/RogerTests/LibraryItemReaderTests.swift Roger/Roger.xcodeproj
git commit -m "feat: read library items from Roger's Markdown files"
```

---
### Task 2: Query, date filter, day grouping and formatting

**Files:**
- Create: `Roger/Services/Library/LibraryQuery.swift`
- Create: `Roger/Services/Library/LibraryDayGrouping.swift`
- Create: `Roger/RogerTests/LibraryFixtures.swift` (shared test helper, used again in Tasks 6 and 9)
- Test: `Roger/RogerTests/LibraryQueryTests.swift`
- Test: `Roger/RogerTests/LibraryDayGroupingTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryItem`, `LibraryItemKind` (Task 1).
- Produces:
  - `enum LibrarySort: String, CaseIterable, Identifiable, Sendable { case newestFirst, oldestFirst, title, duration; var displayName: String; var isByDate: Bool }`
  - `enum LibraryDateFilter: Hashable, Sendable { case any, today, last7Days, last30Days, custom(from: Date, to: Date); func interval(now: Date, calendar: Calendar) -> DateInterval?; var label: String }`
  - `struct LibraryQuery: Equatable, Sendable { var kind: LibraryItemKind?; var dateFilter: LibraryDateFilter; var searchText: String; var sort: LibrarySort; var searchTerms: [String]; func apply(to: [LibraryItem], now: Date = .now, calendar: Calendar = .current) -> [LibraryItem]; static func sorted(_: [LibraryItem], by: LibrarySort) -> [LibraryItem] }`
  - `struct LibraryDaySection: Identifiable, Equatable, Sendable { let id: Date; let title: String; var items: [LibraryItem] }`
  - `enum LibraryDayGrouping { static func sections(_: [LibraryItem], sort: LibrarySort, now: Date = .now, calendar: Calendar = .current) -> [LibraryDaySection]; static func title(for day: Date, now: Date, calendar: Calendar) -> String }`
  - `enum LibraryFormat { static func duration(_ seconds: Int) -> String; static func time(_: Date, calendar: Calendar = .current) -> String; static func longDate(_: Date, calendar: Calendar = .current) -> String; static func metadataLine(for: LibraryItem, calendar: Calendar = .current) -> String }`
  - Test helper `enum LibraryFixtures { static let calendar: Calendar; static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date; static func item(_ name: String, kind: LibraryItemKind = .log, title: String? = nil, date: Date = ..., duration: Int? = nil, body: String = "", folder: String = "/RogerFixtures/Logs/2026/10", audio: [URL] = [], speakers: Int? = nil, language: String? = nil, preset: String? = nil, unfinished: Bool = false) -> LibraryItem }`

- [ ] **Step 1: Write the shared fixtures**

`Roger/RogerTests/LibraryFixtures.swift`:

```swift
import Foundation
@testable import Roger

/// Library items that live only in memory. Paths start with
/// `/RogerFixtures`, which does not exist, so `LibraryPath.canonical`
/// leaves them unchanged.
enum LibraryFixtures {
    /// Fixed time zone so day boundaries do not depend on the machine.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func item(
        _ name: String,
        kind: LibraryItemKind = .log,
        title: String? = nil,
        date: Date = LibraryFixtures.date(2026, 10, 13),
        duration: Int? = nil,
        body: String = "",
        folder: String = "/RogerFixtures/Logs/2026/10",
        audio: [URL] = [],
        speakers: Int? = nil,
        language: String? = nil,
        preset: String? = nil,
        unfinished: Bool = false
    ) -> LibraryItem {
        let title = title ?? name
        return LibraryItem(
            url: URL(fileURLWithPath: "\(folder)/\(name).md"),
            folderURL: URL(fileURLWithPath: folder, isDirectory: true),
            kind: kind,
            title: title,
            date: date,
            durationSeconds: duration,
            language: language,
            preset: preset,
            speakerCount: speakers,
            screenshotCount: 0,
            audioFiles: audio,
            firstLine: body,
            searchText: (title + "\n" + body).lowercased(),
            isUnfinished: unfinished
        )
    }
}
```

- [ ] **Step 2: Write the failing query tests**

`Roger/RogerTests/LibraryQueryTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryQueryTests {
    let calendar = LibraryFixtures.calendar
    let now = LibraryFixtures.date(2026, 10, 14, 10)

    private func titles(_ query: LibraryQuery, _ items: [LibraryItem]) -> [String] {
        query.apply(to: items, now: now, calendar: calendar).map(\.title)
    }

    @Test func filtersByKind() {
        let items = [
            LibraryFixtures.item("log", kind: .log),
            LibraryFixtures.item("meeting", kind: .meeting),
            LibraryFixtures.item("talk", kind: .transcript),
        ]
        #expect(titles(LibraryQuery(kind: .meeting), items) == ["meeting"])
        #expect(titles(LibraryQuery(kind: nil), items).count == 3)
    }

    @Test func todayCoversTheLocalDay() {
        let items = [
            LibraryFixtures.item("early", date: LibraryFixtures.date(2026, 10, 14, 0, 30)),
            LibraryFixtures.item("late", date: LibraryFixtures.date(2026, 10, 14, 23, 30)),
            LibraryFixtures.item("yesterday", date: LibraryFixtures.date(2026, 10, 13, 23, 59)),
        ]
        #expect(Set(titles(LibraryQuery(dateFilter: .today), items)) == ["early", "late"])
    }

    @Test func last7DaysIncludesTodayAndSixDaysBack() {
        let items = [
            LibraryFixtures.item("in", date: LibraryFixtures.date(2026, 10, 8, 0, 1)),
            LibraryFixtures.item("out", date: LibraryFixtures.date(2026, 10, 7, 23, 59)),
        ]
        #expect(titles(LibraryQuery(dateFilter: .last7Days), items) == ["in"])
    }

    @Test func last30DaysIncludesTodayAndTwentyNineDaysBack() {
        let items = [
            LibraryFixtures.item("in", date: LibraryFixtures.date(2026, 9, 15, 0, 1)),
            LibraryFixtures.item("out", date: LibraryFixtures.date(2026, 9, 14, 23, 59)),
        ]
        #expect(titles(LibraryQuery(dateFilter: .last30Days), items) == ["in"])
    }

    @Test func customRangeIncludesTheLastDayAndAcceptsSwappedBounds() {
        let items = [
            LibraryFixtures.item("first", date: LibraryFixtures.date(2026, 10, 1, 0, 5)),
            LibraryFixtures.item("last", date: LibraryFixtures.date(2026, 10, 3, 23, 55)),
            LibraryFixtures.item("after", date: LibraryFixtures.date(2026, 10, 4, 0, 5)),
        ]
        let range = LibraryDateFilter.custom(from: LibraryFixtures.date(2026, 10, 3), to: LibraryFixtures.date(2026, 10, 1))
        #expect(Set(titles(LibraryQuery(dateFilter: range), items)) == ["first", "last"])
    }

    @Test func searchNeedsEveryWordAndIgnoresCase() {
        let items = [
            LibraryFixtures.item("a", body: "Called the Supplier about the shipment"),
            LibraryFixtures.item("b", body: "Called the plumber"),
        ]
        #expect(titles(LibraryQuery(searchText: "SUPPLIER ship"), items) == ["a"])
        #expect(titles(LibraryQuery(searchText: "called"), items).count == 2)
        #expect(titles(LibraryQuery(searchText: "supplier cat"), items).isEmpty)
        #expect(titles(LibraryQuery(searchText: "   "), items).count == 2)
    }

    @Test func sortOrders() {
        let items = [
            LibraryFixtures.item("Log 10", date: LibraryFixtures.date(2026, 10, 2), duration: 30),
            LibraryFixtures.item("Log 2", date: LibraryFixtures.date(2026, 10, 3), duration: nil),
            LibraryFixtures.item("Log 1", date: LibraryFixtures.date(2026, 10, 1), duration: 90),
        ]
        #expect(titles(LibraryQuery(sort: .newestFirst), items) == ["Log 2", "Log 10", "Log 1"])
        #expect(titles(LibraryQuery(sort: .oldestFirst), items) == ["Log 1", "Log 10", "Log 2"])
        #expect(titles(LibraryQuery(sort: .title), items) == ["Log 1", "Log 2", "Log 10"])
        #expect(titles(LibraryQuery(sort: .duration), items) == ["Log 1", "Log 10", "Log 2"])
    }
}
```

- [ ] **Step 3: Write the failing grouping and formatting tests**

`Roger/RogerTests/LibraryDayGroupingTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryDayGroupingTests {
    let calendar = LibraryFixtures.calendar
    let now = LibraryFixtures.date(2026, 10, 14, 10)

    @Test func dayHeaders() {
        let items = [
            LibraryFixtures.item("a", date: LibraryFixtures.date(2026, 10, 14, 9)),
            LibraryFixtures.item("b", date: LibraryFixtures.date(2026, 10, 14, 8)),
            LibraryFixtures.item("c", date: LibraryFixtures.date(2026, 10, 13, 9)),
            LibraryFixtures.item("d", date: LibraryFixtures.date(2026, 10, 12, 9)),
            LibraryFixtures.item("e", date: LibraryFixtures.date(2025, 10, 12, 9)),
        ]
        let sections = LibraryDayGrouping.sections(items, sort: .newestFirst, now: now, calendar: calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Mon, 12 Oct", "Sun, 12 Oct 2025"])
        #expect(sections[0].items.map(\.title) == ["a", "b"])
    }

    @Test func nonDateSortsAreOneSectionWithoutHeader() {
        let items = [LibraryFixtures.item("a"), LibraryFixtures.item("b", date: LibraryFixtures.date(2026, 1, 1))]
        let sections = LibraryDayGrouping.sections(items, sort: .title, now: now, calendar: calendar)
        #expect(sections.count == 1)
        #expect(sections[0].title == "")
        #expect(sections[0].items.count == 2)
    }

    @Test func noItemsNoSections() {
        #expect(LibraryDayGrouping.sections([], sort: .newestFirst, now: now, calendar: calendar).isEmpty)
    }

    @Test func durations() {
        #expect(LibraryFormat.duration(0) == "0 s")
        #expect(LibraryFormat.duration(33) == "33 s")
        #expect(LibraryFormat.duration(60) == "1 min")
        #expect(LibraryFormat.duration(754) == "13 min")
        #expect(LibraryFormat.duration(3590) == "1 h")
        #expect(LibraryFormat.duration(3600) == "1 h")
        #expect(LibraryFormat.duration(3900) == "1 h 5 min")
    }

    @Test func metadataLineForALog() {
        let item = LibraryFixtures.item(
            "x", date: LibraryFixtures.date(2026, 10, 13, 14, 32), duration: 33, language: "de", preset: "Log"
        )
        #expect(LibraryFormat.metadataLine(for: item, calendar: calendar) == "Tue, 13 Oct 2026 · 14:32 · 33 s · de · Log")
    }

    @Test func metadataLineForAMeeting() {
        let item = LibraryFixtures.item(
            "x", kind: .meeting, date: LibraryFixtures.date(2026, 10, 13, 9), duration: 3900, speakers: 1
        )
        #expect(LibraryFormat.metadataLine(for: item, calendar: calendar) == "Tue, 13 Oct 2026 · 09:00 · 1 h 5 min · 1 speaker")
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryQueryTests -only-testing:RogerTests/LibraryDayGroupingTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryQuery' in scope".

- [ ] **Step 5: Write the query**

`Roger/Services/Library/LibraryQuery.swift`:

```swift
import Foundation

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case title
    case duration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newestFirst: return "Newest First"
        case .oldestFirst: return "Oldest First"
        case .title: return "Title"
        case .duration: return "Duration"
        }
    }

    /// Date sorts group the list by day; the others show one flat list.
    var isByDate: Bool { self == .newestFirst || self == .oldestFirst }
}

enum LibraryDateFilter: Hashable, Sendable {
    case any
    case today
    case last7Days
    case last30Days
    /// Whole local days from the earlier to the later date, both included.
    case custom(from: Date, to: Date)

    /// The covered span in whole local days, end exclusive. Nil for `.any`.
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return nil }
        func back(_ days: Int) -> DateInterval? {
            calendar.date(byAdding: .day, value: -days, to: startOfToday).map { DateInterval(start: $0, end: endOfToday) }
        }
        switch self {
        case .any:
            return nil
        case .today:
            return DateInterval(start: startOfToday, end: endOfToday)
        case .last7Days:
            return back(6)
        case .last30Days:
            return back(29)
        case .custom(let a, let b):
            let start = calendar.startOfDay(for: min(a, b))
            let lastDay = calendar.startOfDay(for: max(a, b))
            guard let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    var label: String {
        switch self {
        case .any: return "Any Date"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .custom(let a, let b):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d MMM"
            return "\(f.string(from: min(a, b))) - \(f.string(from: max(a, b)))"
        }
    }
}

/// What the library list shows: kind, date span, search words and order.
struct LibraryQuery: Equatable, Sendable {
    /// Nil shows every kind.
    var kind: LibraryItemKind?
    var dateFilter: LibraryDateFilter = .any
    var searchText = ""
    var sort: LibrarySort = .newestFirst

    /// Lowercased words of `searchText`. Every word must occur in the item.
    var searchTerms: [String] {
        searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func apply(to items: [LibraryItem], now: Date = .now, calendar: Calendar = .current) -> [LibraryItem] {
        let interval = dateFilter.interval(now: now, calendar: calendar)
        let terms = searchTerms
        let matching = items.filter { item in
            if let kind, item.kind != kind { return false }
            if let interval, !(item.date >= interval.start && item.date < interval.end) { return false }
            return terms.allSatisfy { item.searchText.contains($0) }
        }
        return Self.sorted(matching, by: sort)
    }

    static func sorted(_ items: [LibraryItem], by sort: LibrarySort) -> [LibraryItem] {
        items.sorted { a, b in
            switch sort {
            case .newestFirst:
                return a.date != b.date ? a.date > b.date : a.id < b.id
            case .oldestFirst:
                return a.date != b.date ? a.date < b.date : a.id < b.id
            case .title:
                let order = a.title.localizedStandardCompare(b.title)
                return order != .orderedSame ? order == .orderedAscending : a.date > b.date
            case .duration:
                switch (a.durationSeconds, b.durationSeconds) {
                case let (x?, y?) where x != y: return x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.date > b.date
                }
            }
        }
    }
}
```

- [ ] **Step 6: Write grouping and formatting**

`Roger/Services/Library/LibraryDayGrouping.swift`:

```swift
import Foundation

/// One day of the library list.
struct LibraryDaySection: Identifiable, Equatable, Sendable {
    /// Start of the local day; `.distantPast` for the single flat section.
    let id: Date
    /// "Today", "Yesterday", "Mon, 12 Oct"; empty for the flat section.
    let title: String
    var items: [LibraryItem]
}

enum LibraryDayGrouping {
    /// Consecutive items of the same local day form one section, in the
    /// order given. Title and duration sorts give one section without a
    /// title, so the order the user picked is kept.
    static func sections(
        _ items: [LibraryItem],
        sort: LibrarySort,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [LibraryDaySection] {
        guard !items.isEmpty else { return [] }
        guard sort.isByDate else { return [LibraryDaySection(id: .distantPast, title: "", items: items)] }
        var result: [LibraryDaySection] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if result.last?.id == day {
                result[result.count - 1].items.append(item)
            } else {
                result.append(LibraryDaySection(id: day, title: title(for: day, now: now, calendar: calendar), items: [item]))
            }
        }
        return result
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return LibraryFormat.formatter(sameYear ? "EEE, d MMM" : "EEE, d MMM yyyy", calendar: calendar).string(from: day)
    }
}

/// Display strings for the library window. English only, like the rest of Roger's UI.
enum LibraryFormat {
    /// "33 s", "13 min", "1 h", "1 h 5 min".
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 {
            let minutes = Int((Double(seconds) / 60).rounded())
            return minutes >= 60 ? "1 h" : "\(minutes) min"
        }
        var hours = seconds / 3600
        var minutes = Int((Double(seconds % 3600) / 60).rounded())
        if minutes == 60 {
            hours += 1
            minutes = 0
        }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// "14:32".
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    /// "Tue, 13 Oct 2026".
    static func longDate(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("EEE, d MMM yyyy", calendar: calendar).string(from: date)
    }

    /// "Tue, 13 Oct 2026 · 14:32 · 33 s · de · Log · 2 speakers". Parts
    /// that are unknown are left out. Meetings always show the speaker count.
    static func metadataLine(for item: LibraryItem, calendar: Calendar = .current) -> String {
        var parts = [longDate(item.date, calendar: calendar), time(item.date, calendar: calendar)]
        if let seconds = item.durationSeconds { parts.append(duration(seconds)) }
        if let language = item.language { parts.append(language) }
        if let preset = item.preset { parts.append(preset) }
        if let speakers = item.speakerCount, item.kind == .meeting || speakers > 1 {
            parts.append("\(speakers) speaker\(speakers == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }
}
```

- [ ] **Step 7: Regenerate and run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryQueryTests -only-testing:RogerTests/LibraryDayGroupingTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 13 tests passed.

- [ ] **Step 8: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/Library Roger/RogerTests/LibraryFixtures.swift Roger/RogerTests/LibraryQueryTests.swift Roger/RogerTests/LibraryDayGroupingTests.swift Roger/Roger.xcodeproj
git commit -m "feat: filter, search, sort and group library items"
```

---

### Task 3: In-memory library index

**Files:**
- Create: `Roger/Services/Library/LibraryPath.swift`
- Create: `Roger/Services/Library/LibraryIndex.swift`
- Test: `Roger/RogerTests/LibraryIndexTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryItemReader.item(markdownAt:fallbackKind:folder:)`, `LibraryItemReader.meetingItem(sessionFolder:)` (Task 1); `LibraryQuery.apply(to:now:calendar:)`, `LibraryQuery.sorted(_:by:)` (Task 2); existing `LibraryLayout`, `MeetingSessionScanner.sessionFolders(in:maxDepth:)`, `MeetingSessionScanner.isSessionFolder(_:)`, `ExternalTranscriptRegistry(fileURL:)`.
- Produces:
  - `enum LibraryPath { static func canonical(_ url: URL) -> String; static func canonicalURL(_ url: URL, isDirectory: Bool = false) -> URL; static func isPath(_ path: String, inside folder: String) -> Bool; static func components(of path: String, below folder: String) -> [String]; static func nearestExisting(_ url: URL) -> URL }`
  - `protocol LibraryIndex: Sendable { func items() async -> [LibraryItem]; func search(_ query: LibraryQuery) async -> [LibraryItem]; var changes: AsyncStream<Void> { get } }`
  - `struct LibraryScanScope: Equatable, Sendable { let layout: LibraryLayout; let extraFolders: [URL] }`
  - `enum LibraryScanUnit: Hashable, Sendable { case file(String, LibraryItemKind), session(String), tree(String, LibraryItemKind), extraFolder(String), externalList, everything }`
  - `actor InMemoryLibraryIndex: LibraryIndex { nonisolated let scope: LibraryScanScope; nonisolated let changes: AsyncStream<Void>; init(scope: LibraryScanScope, externalFiles: @escaping @Sendable () -> [URL], externalListURL: URL? = nil); func rebuild(); func apply(changedPaths: [String]); func unit(forChangedPath: String) -> LibraryScanUnit? }`. Item ids (`url.path`) are canonical paths.

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/LibraryIndexTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryIndexTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @discardableResult
    private func writeLog(_ layout: LibraryLayout, at date: Date, text: String) throws -> URL {
        let folder = layout.monthFolder(.logs, for: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(LogEntryWriter.baseName(for: date) + ".md")
        let entry = LogEntry(text: text, startedAt: date, endedAt: date.addingTimeInterval(10), presetName: "Log", language: nil)
        try LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func writeMeeting(in parent: URL, name: String, text: String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try MeetingTranscriptWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: text)],
            metadata: .init(
                session: MeetingSession(id: UUID(), folder: folder, startedAt: date),
                durationSeconds: 60, speakerCount: 1, language: nil,
                micPresent: false, systemPresent: false, audioKept: true,
                diarized: false, diarizationFailed: false
            )
        )
        return folder
    }

    private func writeTranscript(_ url: URL, title: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fm = TranscriptFrontmatter(
            title: title, description: "x", tags: ["transcript"],
            sourceDate: date, temporalConfidence: .explicit, status: "stable"
        )
        try (fm.render() + "# \(title)\n\nSome words\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeIndex(
        _ layout: LibraryLayout,
        extras: [URL] = [],
        external: @escaping @Sendable () -> [URL] = { [] },
        listURL: URL? = nil
    ) -> InMemoryLibraryIndex {
        InMemoryLibraryIndex(
            scope: LibraryScanScope(layout: layout, extraFolders: extras),
            externalFiles: external,
            externalListURL: listURL
        )
    }

    @Test func findsEveryKindAndPlace() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        try writeLog(layout, at: date, text: "Called the supplier")
        try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "2026-09-21 09-00", text: "Hello")
        try writeTranscript(layout.monthFolder(.transcripts, for: date).appendingPathComponent("talk.mp4.md"), title: "talk")
        let old = base.appendingPathComponent("Roger Recordings", isDirectory: true)
        try writeMeeting(in: old, name: "2026-01-01 10-00", text: "Old meeting")
        try writeTranscript(old.appendingPathComponent("legacy.mp3.md"), title: "legacy")
        let outside = base.appendingPathComponent("Elsewhere/podcast.m4a.md")
        try writeTranscript(outside, title: "podcast")

        let index = makeIndex(layout, extras: [old], external: { [outside] })
        let items = await index.items()
        #expect(items.filter { $0.kind == .log }.count == 1)
        #expect(items.filter { $0.kind == .meeting }.count == 2)
        #expect(items.filter { $0.kind == .transcript }.count == 3)
        #expect(await index.search(LibraryQuery(kind: .meeting)).count == 2)
        #expect(await index.search(LibraryQuery(searchText: "supplier")).map(\.kind) == [.log])
    }

    @Test func retryLeftoversAreNotItems() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let session = try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "First run")
        // A retry moves the old transcript aside to transcript.previous.md.
        try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "Second run")
        let segment = try #require(try MeetingSegmentWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: "Part")],
            sessionStartedAt: date, chunkStart: date, chunkEnd: date.addingTimeInterval(30),
            folder: session, provisional: false
        ))
        try FileManager.default.copyItem(at: segment, to: session.appendingPathComponent("2020-01-01 00-00-00.previous.md"))
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.previous.md").path))

        let items = await makeIndex(layout).items()
        #expect(items.count == 1)
        #expect(items.first?.url.lastPathComponent == "transcript.md")
        #expect(items.first?.firstLine == "Second run")
    }

    @Test func symlinkedSpellingsAreOneItem() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let url = try writeLog(layout, at: date, text: "One")
        let index = makeIndex(layout)
        let items = await index.items()
        #expect(items.map(\.id) == [LibraryPath.canonical(url)])
        if base.path.hasPrefix("/var/") {
            #expect(LibraryPath.canonical(url).hasPrefix("/private/var/"))
            await index.apply(changedPaths: ["/private" + url.path, url.path])
            #expect(await index.items().count == 1)
        }
        let missing = base.appendingPathComponent("not/there.md")
        #expect(LibraryPath.canonical(missing) == LibraryPath.canonical(base) + "/not/there.md")
    }

    @Test func applyPicksUpNewMonthFolder() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        try writeLog(layout, at: date, text: "First")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)

        let later = date.addingTimeInterval(40 * 86_400)
        let next = try writeLog(layout, at: later, text: "Next month")
        await index.apply(changedPaths: [next.deletingLastPathComponent().path])
        #expect(await index.items().count == 2)
    }

    @Test func applyRemovesADeletedFile() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let url = try writeLog(layout, at: date, text: "Gone soon")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        try FileManager.default.removeItem(at: url)
        await index.apply(changedPaths: [url.path])
        #expect(await index.items().isEmpty)
    }

    @Test func applyReplacesUnfinishedMeetingWhenTranscriptAppears() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = layout.monthFolder(.meetings, for: date).appendingPathComponent("2026-09-21 09-00", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chunk = folder.appendingPathComponent("mic-001.caf")
        try Data().write(to: chunk)
        let index = makeIndex(layout)
        #expect(await index.items().first?.isUnfinished == true)

        try writeMeeting(in: folder.deletingLastPathComponent(), name: folder.lastPathComponent, text: "Done")
        try FileManager.default.removeItem(at: chunk)
        await index.apply(changedPaths: [folder.appendingPathComponent("transcript.md").path, chunk.path])
        let items = await index.items()
        #expect(items.count == 1)
        #expect(items.first?.isUnfinished == false)
        #expect(items.first?.hasMarkdown == true)
    }

    @Test func applyDropsATrashedSession() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let folder = try writeMeeting(in: layout.monthFolder(.meetings, for: date), name: "s", text: "Bye")
        let index = makeIndex(layout)
        #expect(await index.items().count == 1)
        try FileManager.default.removeItem(at: folder)
        await index.apply(changedPaths: [folder.path])
        #expect(await index.items().isEmpty)
    }

    @Test func externalListChangeAddsTheTranscript() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true))
        let registry = ExternalTranscriptRegistry(fileURL: base.appendingPathComponent("Support/external-transcripts.json"))
        let outside = base.appendingPathComponent("Downloads/talk.mp4.md")
        try writeTranscript(outside, title: "talk")
        let index = makeIndex(layout, external: { registry.existingFiles() }, listURL: registry.fileURL)
        #expect(await index.items().isEmpty)

        try registry.add(outside)
        await index.apply(changedPaths: [registry.fileURL.path])
        #expect(await index.items().map(\.title) == ["talk"])
    }

    @Test func changesYieldAfterBuildAndAfterRealChanges() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let index = makeIndex(layout)
        var changes = index.changes.makeAsyncIterator()
        _ = await index.items()
        #expect(await changes.next() != nil)   // the first build

        let url = try writeLog(layout, at: date, text: "New")
        await index.apply(changedPaths: [url.path])
        #expect(await changes.next() != nil)
    }

    @Test func unrelatedPathsAreIgnored() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let index = makeIndex(LibraryLayout(root: base.appendingPathComponent("Roger", isDirectory: true)))
        #expect(await index.unit(forChangedPath: base.appendingPathComponent("Other/file.md").path) == nil)
        #expect(await index.unit(forChangedPath: base.appendingPathComponent("Roger").path) == .everything)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryIndexTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'InMemoryLibraryIndex' in scope".

- [ ] **Step 3: Write `LibraryPath`**

`Roger/Services/Library/LibraryPath.swift`:

```swift
import Foundation

/// Path helpers for the library index. FSEvents reports real paths
/// (`/private/var/...`), so every path the index stores or compares is
/// canonical: the `realpath` of its nearest existing ancestor plus the
/// parts below it that do not exist (yet or any more). Do not use
/// `resolvingSymlinksInPath()` here: it turns `/private/var` into `/var`.
enum LibraryPath {
    static func canonical(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = existing.path
        if let resolved = realpath(existing.path, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        return missing.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func canonicalURL(_ url: URL, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: canonical(url), isDirectory: isDirectory)
    }

    /// True when `path` is `folder` or lies below it.
    static func isPath(_ path: String, inside folder: String) -> Bool {
        if path == folder { return true }
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The components of `path` below `folder`; empty when they are equal
    /// or `path` is not inside `folder`.
    static func components(of path: String, below folder: String) -> [String] {
        guard isPath(path, inside: folder), path != folder else { return [] }
        let prefixLength = folder.hasSuffix("/") ? folder.count : folder.count + 1
        return path.dropFirst(prefixLength).split(separator: "/").map(String.init)
    }

    /// `url` itself or its nearest existing ancestor.
    static func nearestExisting(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}
```

- [ ] **Step 4: Write the index**

`Roger/Services/Library/LibraryIndex.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryIndex")

/// Everything the library window lists, kept current while Roger runs. An
/// in-memory implementation today; a SQLite FTS5 one can replace it behind
/// this protocol if libraries ever grow far beyond a few thousand items.
protocol LibraryIndex: Sendable {
    /// All items, newest first.
    func items() async -> [LibraryItem]
    func search(_ query: LibraryQuery) async -> [LibraryItem]
    /// Yields after the first build and after every change to the items.
    var changes: AsyncStream<Void> { get }
}

/// The folders an index covers: the library root and the extra scan folders.
struct LibraryScanScope: Equatable, Sendable {
    let layout: LibraryLayout
    let extraFolders: [URL]
}

/// What must be read again after a file system change. Paths are canonical.
enum LibraryScanUnit: Hashable, Sendable {
    /// One Markdown file; the kind is the fallback when its tags do not say.
    case file(String, LibraryItemKind)
    /// One meeting session folder.
    case session(String)
    /// A folder below Logs, Meetings or Transcripts, with everything inside.
    case tree(String, LibraryItemKind)
    /// An extra scan folder itself.
    case extraFolder(String)
    /// The external-transcripts list changed.
    case externalList
    /// The library root or one of its parents changed.
    case everything
}

/// Scans `Logs/`, `Meetings/`, `Transcripts/`, the extra scan folders and
/// the external-transcripts list. Built on first use. Keeps one item per
/// canonical path. Meetings come only from session folders and only as
/// their `transcript.md`, so `transcript.previous*.md` and segment files are
/// never listed.
actor InMemoryLibraryIndex: LibraryIndex {
    nonisolated let scope: LibraryScanScope
    nonisolated let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let externalFiles: @Sendable () -> [URL]
    private let externalListPath: String?
    private let root: String
    private let logs: String
    private let meetings: String
    private let transcripts: String
    private let extras: [String]
    private var itemsByID: [String: LibraryItem] = [:]
    private var externalIDs: Set<String> = []
    private var isBuilt = false

    /// `externalFiles` lists transcripts written next to their source
    /// (`ExternalTranscriptRegistry.existingFiles`). `externalListURL` is the
    /// file that list is stored in; a change to it re-reads the list.
    init(
        scope: LibraryScanScope,
        externalFiles: @escaping @Sendable () -> [URL],
        externalListURL: URL? = nil
    ) {
        self.scope = scope
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.changes = stream
        self.continuation = continuation
        self.externalFiles = externalFiles
        self.externalListPath = externalListURL.map { LibraryPath.canonical($0) }
        self.root = LibraryPath.canonical(scope.layout.root)
        self.logs = LibraryPath.canonical(scope.layout.kindFolder(.logs))
        self.meetings = LibraryPath.canonical(scope.layout.kindFolder(.meetings))
        self.transcripts = LibraryPath.canonical(scope.layout.kindFolder(.transcripts))
        self.extras = scope.extraFolders.map { LibraryPath.canonical($0) }
    }

    func items() async -> [LibraryItem] {
        buildIfNeeded()
        return LibraryQuery.sorted(Array(itemsByID.values), by: .newestFirst)
    }

    func search(_ query: LibraryQuery) async -> [LibraryItem] {
        buildIfNeeded()
        return query.apply(to: Array(itemsByID.values))
    }

    /// Reads everything again.
    func rebuild() {
        let start = Date()
        itemsByID = scanAll()
        isBuilt = true
        // Plain locals: Logger interpolation must not touch actor state.
        let count = itemsByID.count
        let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("Library index built: \(count) items in \(milliseconds) ms")
        continuation.yield()
    }

    /// Reads again what `paths` touched. Paths may be spelled as FSEvents
    /// reports them or not. Does nothing before the first build.
    func apply(changedPaths paths: [String]) {
        guard isBuilt else { return }
        let units = Set(paths.compactMap { unit(forChangedPath: $0) })
        guard !units.isEmpty else { return }
        if units.contains(.everything) {
            rebuild()
            return
        }
        let before = itemsByID
        for unit in units { reload(unit) }
        if itemsByID != before { continuation.yield() }
    }

    /// Maps one changed path to what must be read again. Nil for paths
    /// outside the library.
    func unit(forChangedPath raw: String) -> LibraryScanUnit? {
        let path = LibraryPath.canonical(URL(fileURLWithPath: raw))
        if let list = externalListPath, path == list { return .externalList }
        if externalIDs.contains(path) { return .file(path, .transcript) }
        if LibraryPath.isPath(root, inside: path) { return .everything }
        for (folder, kind) in [(logs, LibraryItemKind.log), (transcripts, .transcript)]
        where LibraryPath.isPath(path, inside: folder) {
            let ext = (path as NSString).pathExtension.lowercased()
            if ext == "md" { return .file(path, kind) }
            // Audio next to a log entry: its .md says whether it has audio.
            if ext == "m4a" { return .file((path as NSString).deletingPathExtension + ".md", kind) }
            return ext.isEmpty ? .tree(path, kind) : nil
        }
        if LibraryPath.isPath(path, inside: meetings) {
            let parts = LibraryPath.components(of: path, below: meetings)
            // Meetings/YYYY/MM/<session>/...
            if parts.count >= 3 { return .session(([meetings] + parts.prefix(3)).joined(separator: "/")) }
            return .tree(path, .meeting)
        }
        for extra in extras where LibraryPath.isPath(path, inside: extra) {
            let parts = LibraryPath.components(of: path, below: extra)
            guard let first = parts.first else { return .extraFolder(extra) }
            if parts.count == 1 {
                let ext = (first as NSString).pathExtension.lowercased()
                if ext == "md" { return .file(path, .transcript) }
                if !ext.isEmpty { return nil }
            }
            return .session(extra + "/" + first)
        }
        return nil
    }

    // MARK: - Scanning

    private func buildIfNeeded() {
        if !isBuilt { rebuild() }
    }

    private func reload(_ unit: LibraryScanUnit) {
        switch unit {
        case .file(let path, let kind):
            itemsByID[path] = nil
            if FileManager.default.fileExists(atPath: path),
               let item = LibraryItemReader.item(markdownAt: URL(fileURLWithPath: path), fallbackKind: kind) {
                itemsByID[item.id] = item
            }
        case .session(let path):
            removeAll { $0.kind == .meeting && $0.folderURL.path == path }
            if let item = LibraryItemReader.meetingItem(sessionFolder: URL(fileURLWithPath: path, isDirectory: true)) {
                itemsByID[item.id] = item
            }
        case .tree(let path, let kind):
            removeAll { LibraryPath.isPath($0.url.path, inside: path) || LibraryPath.isPath($0.folderURL.path, inside: path) }
            insert(scanTree(path, kind: kind))
        case .extraFolder(let path):
            removeAll { LibraryPath.isPath($0.url.path, inside: path) }
            insert(scanExtraFolder(path))
        case .externalList:
            let previous = externalIDs
            removeAll { previous.contains($0.id) }
            insert(scanExternal())
        case .everything:
            itemsByID = scanAll()
        }
    }

    private func removeAll(where shouldRemove: (LibraryItem) -> Bool) {
        itemsByID = itemsByID.filter { !shouldRemove($0.value) }
    }

    private func insert(_ items: [LibraryItem]) {
        for item in items { itemsByID[item.id] = item }
    }

    private func scanAll() -> [String: LibraryItem] {
        var found = scanTree(logs, kind: .log)
        found += scanTree(transcripts, kind: .transcript)
        found += scanTree(meetings, kind: .meeting)
        for extra in extras { found += scanExtraFolder(extra) }
        found += scanExternal()
        var result: [String: LibraryItem] = [:]
        for item in found { result[item.id] = item }
        return result
    }

    /// Every item at or below `path`. Meetings: session folders up to three
    /// levels down (`YYYY/MM/<session>`). Logs and transcripts: every `.md`
    /// file. Synchronous on purpose: iterating a `DirectoryEnumerator` is
    /// not allowed in async functions under Swift 6.
    private func scanTree(_ path: String, kind: LibraryItemKind) -> [LibraryItem] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if kind == .meeting {
            let sessions = MeetingSessionScanner.isSessionFolder(url)
                ? [url]
                : MeetingSessionScanner.sessionFolders(in: url, maxDepth: 3)
            return sessions.compactMap { LibraryItemReader.meetingItem(sessionFolder: $0) }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var items: [LibraryItem] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "md" {
            if let item = LibraryItemReader.item(markdownAt: file, fallbackKind: kind) { items.append(item) }
        }
        return items
    }

    /// Sessions stored directly in an extra folder (the pre-library meetings
    /// folder) and `.md` files directly inside it (the pre-library custom
    /// transcripts folder).
    private func scanExtraFolder(_ path: String) -> [LibraryItem] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var items = MeetingSessionScanner.sessionFolders(in: url, maxDepth: 1)
            .compactMap { LibraryItemReader.meetingItem(sessionFolder: $0) }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for file in children where file.pathExtension.lowercased() == "md" {
            if let item = LibraryItemReader.item(markdownAt: file, fallbackKind: .transcript) { items.append(item) }
        }
        return items
    }

    private func scanExternal() -> [LibraryItem] {
        var items: [LibraryItem] = []
        var ids: Set<String> = []
        for file in externalFiles() {
            let url = LibraryPath.canonicalURL(file)
            guard let item = LibraryItemReader.item(markdownAt: url, fallbackKind: .transcript) else { continue }
            items.append(item)
            ids.insert(item.id)
        }
        externalIDs = ids
        return items
    }
}
```

- [ ] **Step 5: Regenerate and run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryIndexTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 10 tests passed. If `symlinkedSpellingsAreOneItem` fails, check that no code path uses `resolvingSymlinksInPath()` or compares a non-canonical `URL.path`.

- [ ] **Step 6: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/Library Roger/RogerTests/LibraryIndexTests.swift Roger/Roger.xcodeproj
git commit -m "feat: in-memory library index"
```

---
### Task 4: FSEvents watcher and index store

**Files:**
- Create: `Roger/Services/Library/LibraryFolderWatcher.swift`
- Create: `Roger/Services/Library/LibraryIndexStore.swift`
- Modify: `Roger/Services/Library/LibraryIndex.swift` (`InMemoryLibraryIndex`: watching)
- Test: `Roger/RogerTests/LibraryFolderWatcherTests.swift`
- Test: `Roger/RogerTests/LibraryIndexStoreTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `InMemoryLibraryIndex`, `LibraryScanScope`, `LibraryPath` (Task 3); existing `ExternalTranscriptRegistry.standard`, `.existingFiles()`, `.fileURL`.
- Produces:
  - `final class LibraryFolderWatcher: @unchecked Sendable { typealias Handler = @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void; let paths: [String]; init(paths: [String], latency: TimeInterval = 0.5, handler: @escaping Handler); @discardableResult func start() -> Bool; func stop() }`
  - `InMemoryLibraryIndex.init(scope:externalFiles:externalListURL:watchesFileSystem: Bool = false)` and `func stopWatching()`. With `watchesFileSystem`, the first build starts an FSEvents stream on the library root (or its nearest existing parent), the extra folders, the folder of the external list and the folders of external transcripts, and applies each batch.
  - `@MainActor final class LibraryIndexStore { init(externalFiles: @escaping @Sendable () -> [URL], externalListURL: URL?, watchesFileSystem: Bool); static func standard() -> LibraryIndexStore; private(set) var current: InMemoryLibraryIndex?; func index(for scope: LibraryScanScope) -> InMemoryLibraryIndex }`. Same scope returns the same index; a new scope stops the old index's watcher and returns a new index.

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/LibraryFolderWatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

private final class PathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ paths: [String]) { lock.withLock { stored += paths } }
    var paths: [String] { lock.withLock { stored } }
}

struct LibraryFolderWatcherTests {
    @Test func watcherReportsNewFiles() async throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let collector = PathCollector()
        let watcher = LibraryFolderWatcher(paths: [LibraryPath.canonical(root)], latency: 0.1) { paths, _ in
            collector.add(paths)
        }
        #expect(watcher.start())
        defer { watcher.stop() }
        // FSEvents needs a moment after start before it reports.
        try await Task.sleep(for: .milliseconds(300))
        let file = root.appendingPathComponent("new.md")
        try Data("x".utf8).write(to: file)
        let expected = LibraryPath.canonical(file)
        var seen = false
        for _ in 0..<50 where !seen {
            seen = collector.paths.contains(expected)
            if !seen { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(seen)
    }

    @Test func watcherKeepsIndexCurrent() async throws {
        let base = try TempFolder.make()
        defer { TempFolder.remove(base) }
        let layout = LibraryLayout(root: base)
        let index = InMemoryLibraryIndex(
            scope: LibraryScanScope(layout: layout, extraFolders: []),
            externalFiles: { [] },
            watchesFileSystem: true
        )
        #expect(await index.items().isEmpty)
        try await Task.sleep(for: .milliseconds(300))

        // A month folder that did not exist when the index was built.
        let folder = layout.monthFolder(.logs, for: Date(timeIntervalSince1970: 1_790_000_000))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fm = TranscriptFrontmatter(
            title: "Live", description: "x", tags: ["log"],
            sourceDate: .now, temporalConfidence: .explicit, status: "stable"
        )
        try (fm.render() + "# Live\n\nWritten while watching\n")
            .write(to: folder.appendingPathComponent("live.md"), atomically: true, encoding: .utf8)

        var titles: [String] = []
        for _ in 0..<50 where titles != ["Live"] {
            titles = await index.items().map(\.title)
            if titles != ["Live"] { try await Task.sleep(for: .milliseconds(100)) }
        }
        await index.stopWatching()
        #expect(titles == ["Live"])
    }
}
```

`Roger/RogerTests/LibraryIndexStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

@MainActor
struct LibraryIndexStoreTests {
    private func store() -> LibraryIndexStore {
        LibraryIndexStore(externalFiles: { [] }, externalListURL: nil, watchesFileSystem: false)
    }

    private func scope(_ root: String, extras: [String] = []) -> LibraryScanScope {
        LibraryScanScope(
            layout: LibraryLayout(root: URL(fileURLWithPath: root, isDirectory: true)),
            extraFolders: extras.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    @Test func sameScopeKeepsTheIndex() {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        let b = store.index(for: scope("/RogerFixtures/A"))
        #expect(a === b)
    }

    @Test func newRootGivesANewIndex() {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        let b = store.index(for: scope("/RogerFixtures/B"))
        #expect(a !== b)
        #expect(store.current === b)
        #expect(b.scope == scope("/RogerFixtures/B"))
    }

    @Test func newExtraFolderGivesANewIndex() {
        let store = store()
        let a = store.index(for: scope("/RogerFixtures/A"))
        let b = store.index(for: scope("/RogerFixtures/A", extras: ["/RogerFixtures/Old"]))
        #expect(a !== b)
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryFolderWatcherTests -only-testing:RogerTests/LibraryIndexStoreTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryFolderWatcher' in scope" and "extra argument 'watchesFileSystem' in call".

- [ ] **Step 3: Write the watcher**

`Roger/Services/Library/LibraryFolderWatcher.swift`:

```swift
import CoreServices
import Foundation

/// Thin wrapper around an `FSEventStream` with file-level events. Reports
/// changed paths (real paths, such as `/private/var/...`) in batches,
/// coalesced over `latency` seconds, on a private queue. `mustRescan` is
/// true when FSEvents dropped events or a watched root changed, so the
/// caller should read everything again. Call `stop()` before releasing it.
final class LibraryFolderWatcher: @unchecked Sendable {
    typealias Handler = @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void

    let paths: [String]
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.jordiboehme.roger.library-watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: TimeInterval = 0.5, handler: @escaping Handler) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// False when there is nothing to watch or FSEvents refused the stream.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<LibraryFolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let changed = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
                let rescan = FSEventStreamEventFlags(
                    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                )
                var mustRescan = false
                for i in 0..<count where eventFlags[i] & rescan != 0 { mustRescan = true }
                watcher.handler(changed, mustRescan)
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// No callback runs after this returns.
    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
        // A callback may already be running; wait so it never touches a released watcher.
        queue.sync {}
    }
}
```

If the compiler rejects an `FSEventStreamCreateFlags(...)` or `FSEventStreamEventFlags(...)` expression because the constants are `Int`, wrap each constant: `FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes) | ...`.

- [ ] **Step 4: Let the index watch**

In `Roger/Services/Library/LibraryIndex.swift`, inside `actor InMemoryLibraryIndex`:

1. Add below `private var isBuilt = false`:

```swift
    private let watchesFileSystem: Bool
    private var watcher: LibraryFolderWatcher?
    private var eventTask: Task<Void, Never>?
```

2. Change the initializer signature and assign the new property (first line of the body):

```swift
    init(
        scope: LibraryScanScope,
        externalFiles: @escaping @Sendable () -> [URL],
        externalListURL: URL? = nil,
        watchesFileSystem: Bool = false
    ) {
        self.watchesFileSystem = watchesFileSystem
        self.scope = scope
```

(the rest of the body stays).

3. At the end of `rebuild()`, after `continuation.yield()`:

```swift
        if watchesFileSystem { restartWatcherIfNeeded() }
```

4. In `reload(_:)`, case `.externalList`, after `insert(scanExternal())`:

```swift
            // A new external transcript may live in a folder nobody watches yet.
            if watchesFileSystem { restartWatcherIfNeeded() }
```

5. Add a new section before `// MARK: - Scanning`:

```swift
    // MARK: - Watching

    /// Stops following file system changes. The items stay.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func restartWatcherIfNeeded() {
        let paths = watchedPaths()
        if let watcher, watcher.paths == paths { return }
        stopWatching()
        let (events, sink) = AsyncStream.makeStream(of: [String]?.self)
        let watcher = LibraryFolderWatcher(paths: paths, latency: 0.5) { changed, mustRescan in
            sink.yield(mustRescan ? nil : changed)
        }
        guard watcher.start() else {
            logger.error("Could not watch the library folders")
            return
        }
        self.watcher = watcher
        eventTask = Task { [weak self] in
            for await batch in events {
                guard let self else { return }
                if let batch {
                    await self.apply(changedPaths: batch)
                } else {
                    await self.rebuild()
                }
            }
        }
    }

    /// The library root (or its nearest existing parent, so the root
    /// appearing is noticed), the extra folders, the folder of the external
    /// list and the folders of external transcripts. FSEvents watches each
    /// recursively, so new `YYYY/MM` folders are covered.
    private func watchedPaths() -> [String] {
        var urls = [LibraryPath.nearestExisting(scope.layout.root)]
        urls += scope.extraFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let list = externalListPath {
            urls.append(LibraryPath.nearestExisting(URL(fileURLWithPath: list).deletingLastPathComponent()))
        }
        urls += externalIDs.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        return Array(Set(urls.map { LibraryPath.canonical($0) })).sorted()
    }
```

- [ ] **Step 5: Write the store**

`Roger/Services/Library/LibraryIndexStore.swift`:

```swift
import Foundation

/// Keeps one live library index for the current library folder and extra
/// folders, so it stays in memory while Roger runs, also after the window
/// closes. A changed scope (new root or extra folders in Settings) gets a
/// fresh index; the old one stops watching.
@MainActor
final class LibraryIndexStore {
    private let externalFiles: @Sendable () -> [URL]
    private let externalListURL: URL?
    private let watchesFileSystem: Bool
    private(set) var current: InMemoryLibraryIndex?

    init(externalFiles: @escaping @Sendable () -> [URL], externalListURL: URL?, watchesFileSystem: Bool) {
        self.externalFiles = externalFiles
        self.externalListURL = externalListURL
        self.watchesFileSystem = watchesFileSystem
    }

    /// The app's store: the real external-transcripts list, with FSEvents.
    static func standard() -> LibraryIndexStore {
        let registry = ExternalTranscriptRegistry.standard
        return LibraryIndexStore(
            externalFiles: { registry.existingFiles() },
            externalListURL: registry.fileURL,
            watchesFileSystem: true
        )
    }

    func index(for scope: LibraryScanScope) -> InMemoryLibraryIndex {
        if let current, current.scope == scope { return current }
        if let old = current {
            Task { await old.stopWatching() }
        }
        let index = InMemoryLibraryIndex(
            scope: scope,
            externalFiles: externalFiles,
            externalListURL: externalListURL,
            watchesFileSystem: watchesFileSystem
        )
        current = index
        return index
    }
}
```

- [ ] **Step 6: Regenerate and run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryFolderWatcherTests -only-testing:RogerTests/LibraryIndexStoreTests -only-testing:RogerTests/LibraryIndexTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 15 tests passed. If `watcherKeepsIndexCurrent` fails, log the paths the watcher reports and compare them with `LibraryPath.canonical`; do not paper over it with a longer sleep.

- [ ] **Step 7: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/Library Roger/RogerTests/LibraryFolderWatcherTests.swift Roger/RogerTests/LibraryIndexStoreTests.swift Roger/Roger.xcodeproj
git commit -m "feat: keep the library index current with FSEvents"
```

---

### Task 5: Documents: load, rename and save with a conflict check

**Files:**
- Create: `Roger/Services/Library/LibraryDocument.swift`
- Test: `Roger/RogerTests/LibraryDocumentTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryFrontmatterParser.split(_:)` (Task 1), `LibraryItem` (Task 1), `LibraryPath` (Task 3), existing `TranscriptFrontmatter.quoted(_:)`.
- Produces:
  - `struct LibraryDocument: Equatable, Sendable { let url: URL; let frontmatter: String; let body: String; let modificationDate: Date?; static func load(_ url: URL) throws -> LibraryDocument }`
  - `enum LibraryDocumentEditor { enum SaveOutcome: Equatable, Sendable { case saved, changedOnDisk, missing }; enum RenameError: LocalizedError { case notRenamable }; static func modificationDate(of: URL) -> Date?; static func normalisedTitle(_: String) -> String?; static func renamed(_ text: String, to title: String) -> String?; static func rename(fileAt: URL, to title: String) throws; static func saveBody(_ body: String, of document: LibraryDocument, overwrite: Bool = false) throws -> SaveOutcome; static func write(_ text: String, to url: URL) throws; static func canEdit(_ item: LibraryItem, activeSessionFolder: URL?) -> Bool }`

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/LibraryDocumentTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryDocumentTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private var entry: LogEntry {
        LogEntry(text: "Called the supplier about the delayed shipment", startedAt: date,
                 endedAt: date.addingTimeInterval(33), presetName: "Log", language: nil)
    }

    private func writeLog(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("entry.md")
        try LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Rename

    @Test func renameChangesOnlyTitleAndHeading() throws {
        let text = LogEntryWriter.content(for: entry, audioFileName: nil, generatedAt: date)
        let heading = try #require(text.components(separatedBy: "\n").first { $0.hasPrefix("# ") })
        let renamed = try #require(LibraryDocumentEditor.renamed(text, to: "Supplier call"))
        let expected = text
            .replacingOccurrences(of: "title: \(TranscriptFrontmatter.quoted(LogEntryWriter.title(for: entry)))\n", with: "title: \"Supplier call\"\n")
            .replacingOccurrences(of: heading + "\n", with: "# Supplier call\n")
        #expect(renamed == expected)
    }

    @Test func renameQuotesAndFlattensTheTitle() throws {
        let text = "---\ntype: source\ntitle: \"Old\"\n---\n\n# Old\n\nBody\n"
        let renamed = try #require(LibraryDocumentEditor.renamed(text, to: "  A \"quoted\": title\nwith a break "))
        #expect(renamed == "---\ntype: source\ntitle: \"A \\\"quoted\\\": title with a break\"\n---\n\n# A \"quoted\": title with a break\n\nBody\n")
    }

    @Test func renameAddsAMissingTitleAfterType() throws {
        let text = "---\ntype: source\ntags: [log]\n---\n\nNo heading here\n"
        #expect(LibraryDocumentEditor.renamed(text, to: "New") == "---\ntype: source\ntitle: \"New\"\ntags: [log]\n---\n\nNo heading here\n")
    }

    @Test func renameWithoutFrontmatterChangesTheHeadingOnly() {
        #expect(LibraryDocumentEditor.renamed("# Old\n\nBody\n", to: "New") == "# New\n\nBody\n")
    }

    @Test func renameNeedsATitleOrHeading() {
        #expect(LibraryDocumentEditor.renamed("Just text\n", to: "New") == nil)
        #expect(LibraryDocumentEditor.renamed("# Old\n", to: "   ") == nil)
    }

    @Test func renameFileKeepsFileName() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        try LibraryDocumentEditor.rename(fileAt: url, to: "Supplier call")
        #expect(try read(url).contains("title: \"Supplier call\"\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["entry.md"])
    }

    // MARK: Save

    @Test func saveReplacesOnlyTheBody() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        #expect(document.frontmatter + document.body == (try read(url)))

        let outcome = try LibraryDocumentEditor.saveBody("\n# Log\n\nFixed a typo\n", of: document)
        #expect(outcome == .saved)
        #expect(try read(url) == document.frontmatter + "\n# Log\n\nFixed a typo\n")
    }

    @Test func saveKeepsTheCreationDate() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        _ = try LibraryDocumentEditor.saveBody("\nNew\n", of: try LibraryDocument.load(url))
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
        #expect(after == created)
    }

    @Test func fileChangedOnDiskIsNotOverwrittenSilently() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        let otherEdit = try read(url) + "Added by another app\n"
        try otherEdit.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(600)], ofItemAtPath: url.path)

        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .changedOnDisk)
        #expect(try read(url) == otherEdit)
    }

    @Test func overwriteKeepsARenameMadeMeanwhile() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        try LibraryDocumentEditor.rename(fileAt: url, to: "Renamed meanwhile")
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(600)], ofItemAtPath: url.path)

        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document) == .changedOnDisk)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document, overwrite: true) == .saved)
        let text = try read(url)
        #expect(text.contains("title: \"Renamed meanwhile\"\n"))
        #expect(text.hasSuffix("---\n\nMine\n"))
    }

    @Test func deletedFileIsNotRecreated() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try writeLog(in: folder)
        let document = try LibraryDocument.load(url)
        try FileManager.default.removeItem(at: url)
        #expect(try LibraryDocumentEditor.saveBody("\nMine\n", of: document, overwrite: true) == .missing)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Editable

    @Test func activeSessionAndUnfinishedMeetingsAreNotEditable() {
        let session = "/RogerFixtures/Meetings/2026/10/2026-10-13 09-00"
        let meeting = LibraryFixtures.item("transcript", kind: .meeting, folder: session)
        let log = LibraryFixtures.item("log")
        var unfinished = LibraryFixtures.item("x", kind: .meeting, folder: session, unfinished: true)
        unfinished.url = URL(fileURLWithPath: session, isDirectory: true)
        let active = URL(fileURLWithPath: session, isDirectory: true)

        #expect(!LibraryDocumentEditor.canEdit(meeting, activeSessionFolder: active))
        #expect(LibraryDocumentEditor.canEdit(meeting, activeSessionFolder: nil))
        #expect(LibraryDocumentEditor.canEdit(log, activeSessionFolder: active))
        #expect(!LibraryDocumentEditor.canEdit(unfinished, activeSessionFolder: nil))
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryDocumentTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryDocumentEditor' in scope".

- [ ] **Step 3: Write the document types**

`Roger/Services/Library/LibraryDocument.swift`:

```swift
import Foundation

/// A library file as read from disk for the detail pane. `frontmatter +
/// body` is exactly the file's text.
struct LibraryDocument: Equatable, Sendable {
    let url: URL
    /// Exact frontmatter text including both `---` lines; empty when the file has none.
    let frontmatter: String
    let body: String
    /// When the file was read; `saveBody` compares it to detect changes by other apps.
    let modificationDate: Date?

    static func load(_ url: URL) throws -> LibraryDocument {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSFilePathErrorKey: url.path])
        }
        let parts = LibraryFrontmatterParser.split(text)
        return LibraryDocument(
            url: url,
            frontmatter: parts.frontmatter.map(String.init) ?? "",
            body: String(parts.body),
            modificationDate: LibraryDocumentEditor.modificationDate(of: url)
        )
    }
}

/// Rename and body edits. File names never change: rename edits the
/// frontmatter `title` and the first H1, and nothing else.
enum LibraryDocumentEditor {
    enum SaveOutcome: Equatable, Sendable {
        case saved
        /// Another app changed the file after it was loaded. Nothing was written.
        case changedOnDisk
        /// The file is gone (moved or deleted). Nothing was written.
        case missing
    }

    enum RenameError: LocalizedError {
        case notRenamable

        var errorDescription: String? {
            "This file has no title or heading Roger can change."
        }
    }

    /// Read without URL resource caching, so a change by another app is seen.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// One line, trimmed. Nil when nothing is left.
    static func normalisedTitle(_ raw: String) -> String? {
        let single = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return single.isEmpty ? nil : single
    }

    /// `text` with the frontmatter `title` (added after `type:` when
    /// missing) and the first H1 set to `title`. Every other byte stays the
    /// same. Nil when the title is empty or the file has neither
    /// frontmatter nor an H1.
    static func renamed(_ text: String, to rawTitle: String) -> String? {
        guard let title = normalisedTitle(rawTitle) else { return nil }
        let parts = LibraryFrontmatterParser.split(text)
        let front = parts.frontmatter.map { replacingTitle(in: String($0), with: title) }
        let (body, hadHeading) = replacingHeading(in: String(parts.body), with: title)
        guard front != nil || hadHeading else { return nil }
        return (front ?? "") + body
    }

    static func rename(fileAt url: URL, to title: String) throws {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), let renamed = renamed(text, to: title) else {
            throw RenameError.notRenamable
        }
        try write(renamed, to: url)
    }

    /// Saves `body` under the file's current frontmatter. Refuses when the
    /// file changed since `document` was loaded (unless `overwrite`) or no
    /// longer exists. The frontmatter is read from disk at save time, so an
    /// overwrite never undoes a rename made in the meantime.
    static func saveBody(_ body: String, of document: LibraryDocument, overwrite: Bool = false) throws -> SaveOutcome {
        let url = document.url
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if !overwrite, modificationDate(of: url) != document.modificationDate { return .changedOnDisk }
        let current = try LibraryDocument.load(url)
        try write(current.frontmatter + body, to: url)
        return .saved
    }

    /// Writes into a scratch folder on the same volume and swaps the file
    /// in with `replaceItemAt`, which keeps the original's creation date,
    /// Finder tags and other attributes. The original is never truncated in
    /// place, so a failed write leaves it intact.
    static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(url.lastPathComponent)
        try Data(text.utf8).write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp)
    }

    /// False for an unfinished meeting without a transcript and for files
    /// in the session folder of a meeting that is being recorded or
    /// finalised.
    static func canEdit(_ item: LibraryItem, activeSessionFolder: URL?) -> Bool {
        guard item.hasMarkdown else { return false }
        guard let activeSessionFolder else { return true }
        return !LibraryPath.isPath(LibraryPath.canonical(item.url), inside: LibraryPath.canonical(activeSessionFolder))
    }

    // MARK: - Helpers

    private static func replacingTitle(in frontmatter: String, with title: String) -> String {
        var lines = frontmatter.components(separatedBy: "\n")
        let line = "title: " + TranscriptFrontmatter.quoted(title)
        if let index = lines.firstIndex(where: { $0.hasPrefix("title:") }) {
            lines[index] = line
        } else if let index = lines.firstIndex(where: { $0.hasPrefix("type:") }) {
            lines.insert(line, at: index + 1)
        } else {
            lines.insert(line, at: 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func replacingHeading(in body: String, with title: String) -> (String, Bool) {
        var lines = body.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("# ") }) else { return (body, false) }
        lines[index] = "# " + title
        return (lines.joined(separator: "\n"), true)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryDocumentTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 12 tests passed. If `saveKeepsTheCreationDate` fails, `replaceItemAt` did not keep the date on this volume: copy the original's `.creationDate` onto the result with `setAttributes` after the swap and keep the test.

- [ ] **Step 5: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/Library/LibraryDocument.swift Roger/RogerTests/LibraryDocumentTests.swift Roger/Roger.xcodeproj
git commit -m "feat: rename and edit library files safely"
```

---
### Task 6: Library window, activation policy, shortcut and model

**Files:**
- Create: `Roger/UI/Library/LibraryModel.swift`
- Create: `Roger/UI/Library/LibraryView.swift`
- Create: `Roger/UI/Library/LibrarySidebarView.swift`
- Create: `Roger/UI/Library/LibraryUnfinishedListView.swift`
- Create: `Roger/App/LibraryWindowController.swift`
- Modify: `Roger/App/RogerApp.swift` (shortcut name, `AppDelegate` wiring, Dock reopen)
- Modify: `Roger/App/AppCoordinator.swift` (`libraryOpener`, `openLibrary(selecting:)`)
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (`activeSessionFolder`)
- Modify: `Roger/UI/MenuBarView.swift` ("Open Library" row, last-entry card)
- Modify: `Roger/UI/SettingsView.swift` (General: Library card with the shortcut recorder)
- Modify: `Roger/UI/RecordingsSettingsView.swift` (remove the Past Recordings card)
- Test: `Roger/RogerTests/LibraryModelTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryIndex`, `LibraryScanScope`, `LibraryPath` (Task 3); `LibraryIndexStore` (Task 4); `LibraryQuery`, `LibraryDateFilter`, `LibrarySort`, `LibraryDayGrouping`, `LibraryDaySection` (Task 2); existing `AppCoordinator.pendingMeetingSessions`, `resumeMeetingFinalisation(_:)`, `dismissPendingMeeting(_:)`, `meetingRecorder`, `appState.libraryLayout`, `appState.libraryRoot`, `appState.extraScanFolders`, `appState.lastLogEntryURL`.
- Produces:
  - `enum LibrarySidebarSelection: Hashable, Sendable { case all, kind(LibraryItemKind), unfinished }`
  - `@MainActor @Observable final class LibraryModel` with `private(set) var index: any LibraryIndex`, `var sidebar: LibrarySidebarSelection`, `var searchText: String`, `var dateFilter: LibraryDateFilter`, `var sort: LibrarySort`, `var selection: Set<LibraryItem.ID>`, `var editingItem: LibraryItem?`, `var isEditing: Bool { get }`, `var renameRequest: LibraryItem.ID?`, `private(set) var results: [LibraryItem]`, `counts: [LibraryItemKind: Int]`, `totalCount: Int`, `isLoading: Bool`, `appliedSearch: String`; `var query: LibraryQuery`, `var searchTerms: [String]`, `var sections: [LibraryDaySection]`, `var selectedItems: [LibraryItem]`; `init(index: any LibraryIndex, searchDebounce: Duration = .milliseconds(150))`, `func start()`, `func stop()`, `func replaceIndex(_:)`, `func select(url: URL)`, `func commitSearch() async`, `func reload() async`.
  - `struct LibraryView: View { @Bindable var model: LibraryModel; let onScopeChange: () -> Void }` (content and detail columns are filled in by Tasks 7 and 8).
  - `@MainActor final class LibraryWindowController: NSObject, NSWindowDelegate { init(coordinator: AppCoordinator, indexStore: LibraryIndexStore); private(set) var isOpen: Bool; func show(selecting url: URL? = nil); func refreshScope() }`
  - `extension KeyboardShortcuts.Name { static let openLibrary }`
  - `AppCoordinator.libraryOpener: (@MainActor (URL?) -> Void)?`, `AppCoordinator.openLibrary(selecting: URL? = nil)`
  - `MeetingRecordingService.activeSessionFolder: URL?` (the folder of the session being recorded or finalised)

- [ ] **Step 1: Write the failing model tests**

`Roger/RogerTests/LibraryModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

private final class FakeLibraryIndex: LibraryIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LibraryItem]
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(_ items: [LibraryItem]) {
        stored = items
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        changes = stream
        self.continuation = continuation
    }

    func items() async -> [LibraryItem] { lock.withLock { stored } }
    func search(_ query: LibraryQuery) async -> [LibraryItem] { query.apply(to: lock.withLock { stored }) }

    func set(_ items: [LibraryItem]) {
        lock.withLock { stored = items }
        continuation.yield()
    }
}

@MainActor
struct LibraryModelTests {
    private let items = [
        LibraryFixtures.item("log1", kind: .log, body: "supplier call"),
        LibraryFixtures.item("log2", kind: .log),
        LibraryFixtures.item("meeting", kind: .meeting, folder: "/RogerFixtures/Meetings/2026/10/s"),
    ]

    @Test func countsPerKind() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        await model.reload()
        #expect(!model.isLoading)
        #expect(model.totalCount == 3)
        #expect(model.counts[.log] == 2)
        #expect(model.counts[.meeting] == 1)
        #expect(model.counts[.transcript] == nil)
    }

    @Test func sidebarKindFiltersResults() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        model.sidebar = .kind(.meeting)
        await model.reload()
        #expect(model.results.map(\.title) == ["meeting"])
        #expect(model.totalCount == 3)
    }

    @Test func searchAppliesAfterCommit() async {
        let model = LibraryModel(index: FakeLibraryIndex(items))
        model.searchText = "SUPPLIER"
        await model.commitSearch()
        #expect(model.appliedSearch == "SUPPLIER")
        #expect(model.results.map(\.title) == ["log1"])
        #expect(model.searchTerms == ["supplier"])
    }

    @Test func pendingSelectionWaitsForItem() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        model.sidebar = .kind(.meeting)
        model.searchText = "nothing"
        await model.commitSearch()

        let late = LibraryFixtures.item("late", kind: .log)
        model.select(url: late.url)
        await model.reload()
        #expect(model.selection.isEmpty)
        #expect(model.sidebar == .all)
        #expect(model.searchText == "")
        #expect(model.appliedSearch == "")

        fake.set(items + [late])
        await model.reload()
        #expect(model.selection == [late.id])
    }

    @Test func selectionDropsItemsThatAreGone() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        await model.reload()
        model.selection = [items[0].id, items[1].id]
        #expect(model.selectedItems.count == 2)
        fake.set([items[1], items[2]])
        await model.reload()
        #expect(model.selection == [items[1].id])
    }

    @Test func editingKeepsTheSelection() async {
        let fake = FakeLibraryIndex(items)
        let model = LibraryModel(index: fake)
        await model.reload()
        model.selection = [items[0].id]
        model.editingItem = items[0]
        fake.set([items[1]])
        await model.reload()
        #expect(model.selection == [items[0].id])
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryModelTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryModel' in scope".

- [ ] **Step 3: Write the model**

`Roger/UI/Library/LibraryModel.swift`:

```swift
import Foundation
import Observation

/// Which list the library shows.
enum LibrarySidebarSelection: Hashable, Sendable {
    case all
    case kind(LibraryItemKind)
    /// `AppCoordinator.pendingMeetingSessions`, not index items.
    case unfinished
}

/// State of the library window over a `LibraryIndex`. Views read it and
/// set its filters; it asks the index again on every change.
@MainActor
@Observable
final class LibraryModel {
    private(set) var index: any LibraryIndex

    var sidebar: LibrarySidebarSelection = .all {
        didSet { if sidebar != oldValue { scheduleReload() } }
    }
    /// What the search field shows. Applied after `searchDebounce`.
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    var dateFilter: LibraryDateFilter = .any {
        didSet { if dateFilter != oldValue { scheduleReload() } }
    }
    var sort: LibrarySort = .newestFirst {
        didSet { if sort != oldValue { scheduleReload() } }
    }
    var selection: Set<LibraryItem.ID> = []
    /// The item whose body the detail pane is editing. The list is locked
    /// meanwhile, and the detail pane keeps showing this item even when a
    /// filter or a refresh hides it, so unsaved text is never dropped.
    var editingItem: LibraryItem?
    var isEditing: Bool { editingItem != nil }
    /// Set by the Rename menu item. The detail pane of that item starts
    /// renaming and clears it.
    var renameRequest: LibraryItem.ID?

    private(set) var results: [LibraryItem] = []
    private(set) var counts: [LibraryItemKind: Int] = [:]
    private(set) var totalCount = 0
    private(set) var isLoading = true
    /// The search text in effect.
    private(set) var appliedSearch = ""

    @ObservationIgnored private var pendingSelectionID: String?
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let searchDebounce: Duration

    init(index: any LibraryIndex, searchDebounce: Duration = .milliseconds(150)) {
        self.index = index
        self.searchDebounce = searchDebounce
    }

    var query: LibraryQuery {
        var kind: LibraryItemKind?
        if case .kind(let selected) = sidebar { kind = selected }
        return LibraryQuery(kind: kind, dateFilter: dateFilter, searchText: appliedSearch, sort: sort)
    }

    var searchTerms: [String] { query.searchTerms }
    var sections: [LibraryDaySection] { LibraryDayGrouping.sections(results, sort: sort) }
    var selectedItems: [LibraryItem] { results.filter { selection.contains($0.id) } }

    /// Follows the index's changes and loads the first results.
    func start() {
        changeTask?.cancel()
        let stream = index.changes
        changeTask = Task { [weak self] in
            for await _ in stream {
                await self?.reload()
            }
        }
        scheduleReload()
    }

    func stop() {
        changeTask?.cancel()
        reloadTask?.cancel()
        searchTask?.cancel()
    }

    /// The library folder or the extra folders changed.
    func replaceIndex(_ newIndex: any LibraryIndex) {
        stop()
        index = newIndex
        isLoading = true
        results = []
        selection = []
        start()
    }

    /// Shows everything and selects the item at `url` as soon as the index
    /// has it (a log entry written a moment ago may not be indexed yet).
    func select(url: URL) {
        pendingSelectionID = LibraryPath.canonical(url)
        sidebar = .all
        dateFilter = .any
        searchText = ""
        appliedSearch = ""
        scheduleReload()
    }

    func commitSearch() async {
        appliedSearch = searchText
        await reload()
    }

    func reload() async {
        let all = await index.items()
        let found = await index.search(query)
        counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        totalCount = all.count
        results = found
        isLoading = false
        let ids = Set(found.map(\.id))
        if let pending = pendingSelectionID, ids.contains(pending) {
            selection = [pending]
            pendingSelectionID = nil
        } else if !isEditing {
            let kept = selection.intersection(ids)
            if kept != selection { selection = kept }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.reload()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let delay = searchDebounce
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commitSearch()
        }
    }
}
```

- [ ] **Step 4: Run the model tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryModelTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 6 tests passed.

- [ ] **Step 5: Expose the active session folder**

In `Roger/Services/MeetingRecording/MeetingRecordingService.swift`, below `var isActive: Bool { ... }`:

```swift
    /// The folder of the session that is being recorded or finalised. The
    /// library must not trash, rename or edit anything in it.
    var activeSessionFolder: URL? {
        isActive ? session?.folder : nil
    }
```

- [ ] **Step 6: Let the coordinator open the library**

In `Roger/App/AppCoordinator.swift`, below `var meetingDropTargetActive: Bool = false`:

```swift
    /// Opens the library window. Set by the AppDelegate, which owns the
    /// window; nil in unit tests.
    @ObservationIgnored var libraryOpener: (@MainActor (URL?) -> Void)?

    /// Opens the library window, with the item at `url` selected when given.
    func openLibrary(selecting url: URL? = nil) {
        libraryOpener?(url)
    }
```

- [ ] **Step 7: Write the sidebar and the unfinished list**

`Roger/UI/Library/LibrarySidebarView.swift`:

```swift
import SwiftUI

struct LibrarySidebarView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: Binding(
            get: { Optional(model.sidebar) },
            set: { if let value = $0 { model.sidebar = value } }
        )) {
            Section("Library") {
                row(.all, title: "All", systemImage: "tray.full", count: model.totalCount)
                ForEach(LibraryItemKind.allCases, id: \.self) { kind in
                    row(.kind(kind), title: kind.pluralName, systemImage: kind.systemImage, count: model.counts[kind] ?? 0)
                }
            }
            if !coordinator.pendingMeetingSessions.isEmpty {
                Section("Needs Attention") {
                    row(.unfinished, title: "Unfinished", systemImage: "exclamationmark.triangle",
                        count: coordinator.pendingMeetingSessions.count)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ selection: LibrarySidebarSelection, title: String, systemImage: String, count: Int) -> some View {
        Label(title, systemImage: systemImage)
            .badge(count)
            .tag(selection)
    }
}
```

`Roger/UI/Library/LibraryUnfinishedListView.swift`:

```swift
import AppKit
import SwiftUI

/// Exactly `AppCoordinator.pendingMeetingSessions`: unfinished meetings
/// that were not dismissed. Finalise runs the existing retry; Dismiss uses
/// the existing persisted dismissal.
struct LibraryUnfinishedListView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        List(coordinator.pendingMeetingSessions) { session in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tray.full")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting \(MeetingTranscriptWriter.displayDate(session.startedAt))")
                        .font(.system(size: 13, weight: .medium))
                    Text(session.folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Finalise") {
                    Task { await coordinator.resumeMeetingFinalisation(session) }
                }
                .disabled(coordinator.meetingRecorder.isActive)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.folder])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                Button {
                    coordinator.dismissPendingMeeting(session)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss. The files stay where they are.")
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
        }
        .overlay {
            if coordinator.pendingMeetingSessions.isEmpty {
                ContentUnavailableView("Nothing Unfinished", systemImage: "checkmark.circle")
            }
        }
    }
}
```

- [ ] **Step 8: Write the first version of the library view**

`Roger/UI/Library/LibraryView.swift` (the content column becomes `LibraryListView` in Task 7, the detail column `LibraryDetailView` in Task 8):

```swift
import SwiftUI

struct LibraryView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel
    /// Called when the library folder or the extra folders change.
    let onScopeChange: () -> Void

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } content: {
            Group {
                if model.sidebar == .unfinished {
                    LibraryUnfinishedListView()
                } else {
                    List(model.results, selection: $model.selection) { item in
                        Text(item.title).lineLimit(1)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            .overlay {
                if model.isLoading {
                    ProgressView("Reading the library")
                }
            }
        } detail: {
            Text(model.selection.isEmpty ? "No selection" : "\(model.selection.count) selected")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Roger Library")
        .frame(minWidth: 900, minHeight: 520)
        .onChange(of: coordinator.appState.libraryRoot) { _, _ in onScopeChange() }
        .onChange(of: coordinator.appState.extraScanFolders) { _, _ in onScopeChange() }
        .onChange(of: coordinator.pendingMeetingSessions.isEmpty) { _, isEmpty in
            if isEmpty && model.sidebar == .unfinished { model.sidebar = .all }
        }
    }
}
```

- [ ] **Step 9: Write the window controller**

`Roger/App/LibraryWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Owns the library window: an NSWindow hosting `LibraryView`, created once
/// and reused. While it is open, Roger is a regular app (Dock icon, Cmd-Tab,
/// main menu with Settings and Cmd-,). When it closes, Roger is a menu bar
/// app again. A SwiftUI `Window` scene is not used because `openWindow` is
/// not reachable from the AppKit popover.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "RogerLibraryWindow"

    private let coordinator: AppCoordinator
    private let indexStore: LibraryIndexStore
    private var window: NSWindow?
    private var model: LibraryModel?
    private var scope: LibraryScanScope?
    /// True from `show` until the window closes (also while miniaturised).
    private(set) var isOpen = false

    init(coordinator: AppCoordinator, indexStore: LibraryIndexStore) {
        self.coordinator = coordinator
        self.indexStore = indexStore
    }

    func show(selecting url: URL? = nil) {
        let window = self.window ?? makeWindow()
        refreshScope()
        if let url { model?.select(url: url) }
        isOpen = true
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        // Right after the policy change the menu bar can still belong to the
        // previous app. Activating on the next run loop turn fixes that.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Points the window at the current library folder and extra folders.
    func refreshScope() {
        let current = currentScope()
        guard current != scope else { return }
        scope = current
        model?.replaceIndex(indexStore.index(for: current))
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        NSApp.setActivationPolicy(.accessory)
    }

    private func currentScope() -> LibraryScanScope {
        LibraryScanScope(
            layout: coordinator.appState.libraryLayout,
            extraFolders: coordinator.appState.extraScanFolders
        )
    }

    private func makeWindow() -> NSWindow {
        let scope = currentScope()
        self.scope = scope
        let model = LibraryModel(index: indexStore.index(for: scope))
        let root = LibraryView(model: model, onScopeChange: { [weak self] in self?.refreshScope() })
            .environment(coordinator)
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // Keep the saved frame; do not let SwiftUI resize the window.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.title = "Roger Library"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 900, height: 520)
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 1100, height: 700))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)

        model.start()
        self.model = model
        self.window = window
        return window
    }
}
```

- [ ] **Step 10: Wire it into the app delegate**

In `Roger/App/RogerApp.swift`:

1. In the `extension KeyboardShortcuts.Name` block, below `meetingRecordingToggle`:

```swift
    /// Global hotkey to open the library window. Unset by default, set in
    /// Settings > General.
    static let openLibrary = Self("openLibrary")
```

2. In `AppDelegate`, below `private var onboardingWindow: NSWindow?`:

```swift
    private var libraryWindowController: LibraryWindowController?
```

3. In `applicationDidFinishLaunching`, right after `installStatusItem(coordinator: coordinator)`:

```swift
        coordinator.libraryOpener = { [weak self] url in
            self?.openLibrary(selecting: url)
        }
```

and right after the `KeyboardShortcuts.onKeyDown(for: .meetingRecordingToggle) { ... }` block:

```swift
        KeyboardShortcuts.onKeyDown(for: .openLibrary) {
            Task { @MainActor in
                sharedCoordinator.openLibrary()
            }
        }
```

4. Add a new section before `// MARK: - Drag & Drop`:

```swift
    // MARK: - Library

    func openLibrary(selecting url: URL? = nil) {
        popover?.performClose(nil)
        let controller = libraryWindowController
            ?? LibraryWindowController(coordinator: sharedCoordinator, indexStore: .standard())
        libraryWindowController = controller
        controller.show(selecting: url)
    }

    /// Clicking the Dock icon (only there while the library is open) brings
    /// the library to the front.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller = libraryWindowController, controller.isOpen {
            controller.show()
        }
        return false
    }
```

- [ ] **Step 11: Popover entry points**

In `Roger/UI/MenuBarView.swift`:

1. Replace the call `LastDictationCard(text: text, logURL: coordinator.appState.lastLogEntryURL)` with:

```swift
                LastDictationCard(
                    text: text,
                    logURL: coordinator.appState.lastLogEntryURL,
                    onShowInLibrary: { coordinator.openLibrary(selecting: $0) }
                )
```

2. In the bottom `VStack(spacing: 0)`, insert before `SettingsLink {`:

```swift
                Button {
                    coordinator.openLibrary()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text("Open Library")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
```

3. In `private struct LastDictationCard`, add below `let logURL: URL?`:

```swift
    let onShowInLibrary: (URL) -> Void
```

and replace the log button (the one that calls `NSWorkspace.shared.activateFileViewerSelecting([logURL])`) with:

```swift
                Button {
                    onShowInLibrary(logURL)
                } label: {
                    Label("Saved to log - Show in Library", systemImage: "book.closed")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
```

- [ ] **Step 12: Shortcut recorder in General settings**

In `Roger/UI/SettingsView.swift`, add `import KeyboardShortcuts` below `import ApplicationServices`. In `GeneralSettingsView.body`, add a card after the "Startup" card:

```swift
                // Library
                settingsCard(icon: "books.vertical", title: "Library") {
                    VStack(alignment: .leading, spacing: 8) {
                        settingsRow("Open Library") {
                            KeyboardShortcuts.Recorder(for: .openLibrary)
                                .shortcutValidation { shortcut in
                                    if shortcut.key == .f18 {
                                        return .disallow(reason: "F18 is Roger's dictation hotkey (Caps Lock).")
                                    }
                                    return .allow
                                }
                        }
                        Text("Optional. Set a global shortcut to open the library window.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 13: Remove the Past Recordings card**

In `Roger/UI/RecordingsSettingsView.swift`:

1. Delete `@State private var sessions: [SessionRow] = []`.
2. Delete the whole `// Library` block that builds `settingsCard(icon: "list.bullet.rectangle", title: "Past Recordings") { ... }`.
3. In the `.fileImporter` completion, delete the `refresh()` call (keep `state.libraryRoot = url`).
4. Delete `.onAppear { refresh() }`, `.onChange(of: state.libraryRoot) { _, _ in refresh() }` and `.onChange(of: state.extraScanFolders) { _, _ in refresh() }`.
5. Delete `private func refresh()`, `private func pastSessionRow(_:)`, `private struct SessionRow` and `private struct Tag`.
6. In the Library Folder card, replace the `Button("Reveal in Finder") { revealLibraryFolder() }` line and its two modifiers with:

```swift
                            Button("Open Library") { coordinator.openLibrary() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            Button("Reveal in Finder") { revealLibraryFolder() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
```

7. Update the type's doc comment to: "Settings tab for meeting recording and the library folder: where files go, extra folders, Keep audio, hotkey, speakers, cleanup and chunk length. Browsing past recordings happens in the library window."

Run `grep -n "SessionRow\|Tag(\|refresh()" Roger/UI/RecordingsSettingsView.swift`: it must print nothing.

- [ ] **Step 14: Build, test and check by hand**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "warning:|error:|BUILD" | tail -20
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` with no new warnings in the files of this task, `** TEST SUCCEEDED **`.

Then run the Debug app (quit any running Roger first: `pkill -x Roger`; `open` the `Roger.app` from the build's `BUILT_PRODUCTS_DIR`, found with `xcodebuild -project Roger.xcodeproj -scheme Roger -showBuildSettings | grep -m1 BUILT_PRODUCTS_DIR`) and check:
- Popover > Open Library opens the window, a Dock icon appears, Cmd-Tab lists Roger, the menu bar shows Roger's menus, Roger > Settings… and Cmd-, open Settings.
- Closing the window removes the Dock icon. Open it again: same size and place.
- With the window open, clicking the Dock icon brings it to the front.
- Settings > General > Library: record a shortcut; it opens the library from another app.
- The sidebar shows All, Logs, Meetings, Transcripts with counts.

- [ ] **Step 15: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/UI/Library Roger/App/LibraryWindowController.swift Roger/App/RogerApp.swift Roger/App/AppCoordinator.swift Roger/Services/MeetingRecording/MeetingRecordingService.swift Roger/UI/MenuBarView.swift Roger/UI/SettingsView.swift Roger/UI/RecordingsSettingsView.swift Roger/RogerTests/LibraryModelTests.swift Roger/Roger.xcodeproj
git commit -m "feat: library window with Dock icon while open"
```

---
### Task 7: List grouped by day, toolbar and empty states

**Files:**
- Create: `Roger/UI/Library/LibraryEmptyState.swift`
- Create: `Roger/UI/Library/LibraryListView.swift`
- Create: `Roger/UI/Library/LibraryToolbar.swift`
- Modify: `Roger/UI/Library/LibraryView.swift`
- Test: `Roger/RogerTests/LibraryEmptyStateTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryModel`, `LibrarySidebarSelection` (Task 6); `LibraryFormat`, `LibraryDateFilter`, `LibrarySort` (Task 2); existing `AppState.pendingSettingsTab`, `SettingsTab.presets`.
- Produces:
  - `struct LibraryEmptyState: Equatable { let title: String; let message: String; let systemImage: String; let showsPresetsButton: Bool; static func make(sidebar: LibrarySidebarSelection, searchText: String, dateFilter: LibraryDateFilter) -> LibraryEmptyState }`
  - `struct LibraryEmptyStateView: View { let state: LibraryEmptyState }`
  - `struct LibraryListView: View { @Bindable var model: LibraryModel }` and `struct LibraryItemRow: View { let item: LibraryItem; let showsDate: Bool }` (Task 9 adds actions to `LibraryListView`).
  - `struct LibraryDateFilterMenu: View`, `struct LibrarySortMenu: View` (both take `@Bindable var model: LibraryModel`).

- [ ] **Step 1: Write the failing empty-state tests**

`Roger/RogerTests/LibraryEmptyStateTests.swift`:

```swift
import Testing
@testable import Roger

struct LibraryEmptyStateTests {
    @Test func searchComesFirst() {
        let state = LibraryEmptyState.make(sidebar: .kind(.log), searchText: "supplier", dateFilter: .today)
        #expect(state.title == "No Results")
        #expect(state.message == "Nothing matches \"supplier\".")
        #expect(!state.showsPresetsButton)
    }

    @Test func dateFilterComesNext() {
        let state = LibraryEmptyState.make(sidebar: .all, searchText: "", dateFilter: .last7Days)
        #expect(state.title == "Nothing in This Time Span")
    }

    @Test func emptyLogsPointToThePresets() {
        let state = LibraryEmptyState.make(sidebar: .kind(.log), searchText: "", dateFilter: .any)
        #expect(state.title == "No Log Entries")
        #expect(state.message == "No log entries yet. Bind the Log preset to Caps+⌥ in Settings → Presets.")
        #expect(state.showsPresetsButton)
    }

    @Test func otherKindsHaveHints() {
        #expect(LibraryEmptyState.make(sidebar: .kind(.meeting), searchText: "", dateFilter: .any).message
            == "No meetings yet. Start a recording from the menu bar.")
        #expect(LibraryEmptyState.make(sidebar: .kind(.transcript), searchText: "", dateFilter: .any).message
            == "No transcripts yet. Drop an audio or video file on the menu bar icon.")
        #expect(LibraryEmptyState.make(sidebar: .all, searchText: "", dateFilter: .any).message
            == "Save a log entry, record a meeting or drop a file on the menu bar icon.")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryEmptyStateTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryEmptyState' in scope".

- [ ] **Step 3: Write the empty state**

`Roger/UI/Library/LibraryEmptyState.swift`:

```swift
import SwiftUI

/// What an empty list says. A search or date filter explains itself first;
/// otherwise each kind gets a hint how to make its first entry.
struct LibraryEmptyState: Equatable {
    let title: String
    let message: String
    let systemImage: String
    let showsPresetsButton: Bool

    static func make(sidebar: LibrarySidebarSelection, searchText: String, dateFilter: LibraryDateFilter) -> LibraryEmptyState {
        if !searchText.isEmpty {
            return .init(title: "No Results", message: "Nothing matches \"\(searchText)\".",
                         systemImage: "magnifyingglass", showsPresetsButton: false)
        }
        if dateFilter != .any {
            return .init(title: "Nothing in This Time Span", message: "Try a wider date filter.",
                         systemImage: "calendar", showsPresetsButton: false)
        }
        switch sidebar {
        case .kind(.log):
            return .init(title: "No Log Entries",
                         message: "No log entries yet. Bind the Log preset to Caps+⌥ in Settings → Presets.",
                         systemImage: "book.closed", showsPresetsButton: true)
        case .kind(.meeting):
            return .init(title: "No Meetings", message: "No meetings yet. Start a recording from the menu bar.",
                         systemImage: "person.2", showsPresetsButton: false)
        case .kind(.transcript):
            return .init(title: "No Transcripts",
                         message: "No transcripts yet. Drop an audio or video file on the menu bar icon.",
                         systemImage: "doc.text", showsPresetsButton: false)
        case .all, .unfinished:
            return .init(title: "Nothing Here Yet",
                         message: "Save a log entry, record a meeting or drop a file on the menu bar icon.",
                         systemImage: "books.vertical", showsPresetsButton: false)
        }
    }
}

struct LibraryEmptyStateView: View {
    @Environment(AppCoordinator.self) private var coordinator
    let state: LibraryEmptyState

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: state.systemImage)
        } description: {
            Text(state.message)
        } actions: {
            if state.showsPresetsButton {
                SettingsLink {
                    Text("Open Presets Settings")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    coordinator.appState.pendingSettingsTab = .presets
                })
            }
        }
    }
}
```

- [ ] **Step 4: Write the list**

`Roger/UI/Library/LibraryListView.swift`:

```swift
import SwiftUI

/// The middle column: items grouped by day (date sorts) with sticky
/// headers, multi-selection with Cmd and Shift.
struct LibraryListView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                if section.title.isEmpty {
                    rows(section.items)
                } else {
                    Section(section.title) {
                        rows(section.items)
                    }
                }
            }
        }
        .listStyle(.inset)
        .disabled(model.isEditing)
        .overlay { overlay }
    }

    private func rows(_ items: [LibraryItem]) -> some View {
        ForEach(items) { item in
            LibraryItemRow(item: item, showsDate: !model.sort.isByDate)
                .tag(item.id)
        }
    }

    @ViewBuilder private var overlay: some View {
        if model.isLoading {
            ProgressView("Reading the library")
        } else if model.results.isEmpty {
            LibraryEmptyStateView(state: LibraryEmptyState.make(
                sidebar: model.sidebar,
                searchText: model.appliedSearch,
                dateFilter: model.dateFilter
            ))
        }
    }
}

/// Type icon, title, first line, time, duration and markers for audio,
/// screenshots and speakers.
struct LibraryItemRow: View {
    let item: LibraryItem
    /// Title and duration sorts have no day headers, so rows show the date.
    let showsDate: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(item.isUnfinished ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !item.firstLine.isEmpty {
                    Text(item.firstLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(showsDate
                         ? "\(LibraryFormat.longDate(item.date)) \(LibraryFormat.time(item.date))"
                         : LibraryFormat.time(item.date))
                    if let seconds = item.durationSeconds {
                        Text(LibraryFormat.duration(seconds))
                    }
                    if item.hasAudio {
                        Image(systemName: "waveform").help("Has audio")
                    }
                    if item.screenshotCount > 0 {
                        Label("\(item.screenshotCount)", systemImage: "photo").help("Screenshots")
                    }
                    if let speakers = item.speakerCount, speakers > 1 {
                        Label("\(speakers)", systemImage: "person.2").help("Speakers")
                    }
                    if item.isUnfinished {
                        Text("Unfinished").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }
}
```

- [ ] **Step 5: Write the toolbar menus**

`Roger/UI/Library/LibraryToolbar.swift`:

```swift
import SwiftUI

struct LibraryDateFilterMenu: View {
    @Bindable var model: LibraryModel
    @State private var showsCustomRange = false
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        Menu {
            Picker("Date", selection: $model.dateFilter) {
                Text("Any Date").tag(LibraryDateFilter.any)
                Text("Today").tag(LibraryDateFilter.today)
                Text("Last 7 Days").tag(LibraryDateFilter.last7Days)
                Text("Last 30 Days").tag(LibraryDateFilter.last30Days)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Custom Range…") { showsCustomRange = true }
        } label: {
            Label(model.dateFilter.label, systemImage: "calendar")
        }
        .help("Filter by date")
        .popover(isPresented: $showsCustomRange) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Cancel") { showsCustomRange = false }
                    Button("Apply") {
                        model.dateFilter = .custom(from: from, to: to)
                        showsCustomRange = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 280)
        }
    }
}

struct LibrarySortMenu: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.displayName).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort")
    }
}
```

- [ ] **Step 6: Use them in the library view**

In `Roger/UI/Library/LibraryView.swift`:

1. Add below `let onScopeChange: () -> Void`:

```swift
    @FocusState private var searchFocused: Bool
```

2. Replace the `List(model.results, selection: $model.selection) { item in Text(item.title).lineLimit(1) }` in the content column with:

```swift
                    LibraryListView(model: model)
```

and delete the `.overlay { if model.isLoading { ProgressView("Reading the library") } }` on that column (the list has its own overlay now).

3. Add these modifiers directly after `.navigationTitle("Roger Library")`:

```swift
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search titles and text")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItemGroup {
                LibraryDateFilterMenu(model: model)
                LibrarySortMenu(model: model)
            }
        }
        .background {
            // Cmd-F focuses the search field. The default Find menu item is
            // not wired to `.searchable` in an AppKit-hosted window.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
```

- [ ] **Step 7: Regenerate, test and check by hand**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` (4 new tests). Then run the Debug app and check:
- Rows are grouped under "Today", "Yesterday", "Mon, 12 Oct"; the headers stay at the top while scrolling.
- Cmd-F focuses the search field; typing filters after a short pause; two words must both match.
- The date menu filters; "Custom Range…" applies a range and the menu label shows it.
- Sort by Title or Duration shows a flat list with dates in the rows.
- An empty Logs list shows the hint and "Open Presets Settings" opens Settings on the Presets tab.

- [ ] **Step 8: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/UI/Library Roger/RogerTests/LibraryEmptyStateTests.swift Roger/Roger.xcodeproj
git commit -m "feat: day-grouped library list with search, date filter and sort"
```

---

### Task 8: Detail pane with preview, rename and edit

**Files:**
- Create: `Roger/Services/Library/LibraryMarkdown.swift`
- Create: `Roger/UI/Library/LibraryDetailView.swift`
- Modify: `Roger/UI/Library/LibraryView.swift` (detail column)
- Test: `Roger/RogerTests/LibraryMarkdownTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryDocument`, `LibraryDocumentEditor.saveBody/rename/canEdit` (Task 5); `LibraryModel` (`selectedItems`, `searchTerms`, `editingItem`, `isEditing`, `renameRequest`) (Task 6); `LibraryFormat.metadataLine(for:)` (Task 2); `MeetingRecordingService.activeSessionFolder` (Task 6); existing `MeetingTranscriptWriter.write(paragraphs:metadata:markers:)`, `MeetingCheckpointMarker`.
- Produces:
  - `enum LibraryMarkdownBlock: Equatable, Sendable { case heading(level: Int, text: String), paragraph(String), image(alt: String, url: URL) }`
  - `enum LibraryMarkdown { static func blocks(from body: String, baseURL: URL) -> [LibraryMarkdownBlock]; static func highlightRanges(of terms: [String], in text: String) -> [Range<String.Index>]; static func attributed(_ text: String, highlighting terms: [String]) -> AttributedString }`
  - `struct LibraryDetailView: View { @Bindable var model: LibraryModel }`, `struct LibraryItemDetail: View { let item: LibraryItem; @Bindable var model: LibraryModel }` (Task 11 inserts the extra-files section into `LibraryItemDetail.preview`).

- [ ] **Step 1: Write the failing Markdown tests**

`Roger/RogerTests/LibraryMarkdownTests.swift`:

```swift
import Foundation
import SwiftUI
import Testing
@testable import Roger

struct LibraryMarkdownTests {
    private let base = URL(fileURLWithPath: "/RogerFixtures/Meetings/2026/10/s", isDirectory: true)

    @Test func headingsParagraphsAndImages() {
        let body = "\n# Meeting\n\n**Me** [00:00:01]\nHello there\n\n![Screenshot at 00:01:00](2026-10-13%2009-01-00.png)\n\n## Notes\nLine one\nLine two\n"
        #expect(LibraryMarkdown.blocks(from: body, baseURL: base) == [
            .heading(level: 1, text: "Meeting"),
            .paragraph("**Me** [00:00:01]\nHello there"),
            .image(alt: "Screenshot at 00:01:00", url: base.appendingPathComponent("2026-10-13 09-01-00.png").standardizedFileURL),
            .heading(level: 2, text: "Notes"),
            .paragraph("Line one\nLine two"),
        ])
    }

    @Test func remoteImagesAndHashtagsStayText() {
        let body = "![logo](https://example.com/a.png)\n\n#hashtag is not a heading\n"
        #expect(LibraryMarkdown.blocks(from: body, baseURL: base) == [
            .paragraph("![logo](https://example.com/a.png)"),
            .paragraph("#hashtag is not a heading"),
        ])
    }

    @Test func meetingScreenshotsResolveToTheSessionFolder() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let marker = MeetingCheckpointMarker(
            id: UUID(), capturedAt: start.addingTimeInterval(5), offsetSeconds: 5,
            stemDate: start.addingTimeInterval(5), imageFile: "2026-09-21 16-13-25.png"
        )
        let url = try MeetingTranscriptWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 10, text: "After the slide")],
            metadata: .init(session: MeetingSession(id: UUID(), folder: folder, startedAt: start),
                            durationSeconds: 60, speakerCount: 1, language: nil, micPresent: true,
                            systemPresent: false, audioKept: true, diarized: false, diarizationFailed: false),
            markers: [marker]
        )
        let document = try LibraryDocument.load(url)
        let images = LibraryMarkdown.blocks(from: document.body, baseURL: folder).compactMap { block -> URL? in
            if case .image(_, let url) = block { return url }
            return nil
        }
        #expect(images == [folder.appendingPathComponent("2026-09-21 16-13-25.png").standardizedFileURL])
    }

    @Test func highlightRangesIgnoreCase() {
        let text = "Supplier called. The supplier said yes."
        let found = LibraryMarkdown.highlightRanges(of: ["supplier"], in: text).map { String(text[$0]) }
        #expect(found == ["Supplier", "supplier"])
        #expect(LibraryMarkdown.highlightRanges(of: [], in: text).isEmpty)
    }

    @Test func attributedHighlightsTheMatchesOnly() {
        let result = LibraryMarkdown.attributed("Call the **supplier** now", highlighting: ["supplier"])
        #expect(String(result.characters) == "Call the supplier now")
        let marked = result.runs
            .filter { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil }
            .map { String(result[$0.range].characters) }
            .joined()
        #expect(marked == "supplier")
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryMarkdownTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryMarkdown' in scope".

- [ ] **Step 3: Write the Markdown helpers**

`Roger/Services/Library/LibraryMarkdown.swift`:

```swift
import Foundation
import SwiftUI

/// One block of the simple Markdown preview.
enum LibraryMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Consecutive non-empty lines, joined with line breaks kept.
    case paragraph(String)
    /// A local image on a line of its own (meeting screenshots).
    case image(alt: String, url: URL)
}

/// The preview's Markdown: headings, paragraphs with inline bold and
/// italics, and local images. Not a full CommonMark renderer.
enum LibraryMarkdown {
    static func blocks(from body: String, baseURL: URL) -> [LibraryMarkdownBlock] {
        var blocks: [LibraryMarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let heading = heading(line) {
                flush()
                blocks.append(heading)
            } else if let image = image(line, baseURL: baseURL) {
                flush()
                blocks.append(image)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// `# Title` up to `###### Title`; a space after the hashes is required.
    static func heading(_ line: String) -> LibraryMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    /// `![alt](target)` alone on a line with a local target. Roger writes
    /// targets percent-encoded (spaces as `%20`).
    static func image(_ line: String, baseURL: URL) -> LibraryMarkdownBlock? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let close = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
        let target = String(line[close.upperBound..<line.index(before: line.endIndex)])
        guard !target.contains("://"), let decoded = target.removingPercentEncoding, !decoded.isEmpty else { return nil }
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL.appendingPathComponent(decoded)
        return .image(alt: alt, url: url.standardizedFileURL)
    }

    /// Every case-insensitive occurrence of each term, in text order.
    static func highlightRanges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text.range(of: term, options: .caseInsensitive, range: start..<text.endIndex) {
                ranges.append(found)
                start = found.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Inline Markdown (bold, italics, code) with search matches highlighted.
    static func attributed(_ text: String, highlighting terms: [String]) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let plain = String(result.characters)
        for range in highlightRanges(of: terms, in: plain) {
            let offset = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let start = result.characters.index(result.startIndex, offsetBy: offset)
            let end = result.characters.index(start, offsetBy: length)
            // Explicit keys: AppKit and SwiftUI both define these attributes.
            result[start..<end][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.yellow.opacity(0.45)
            result[start..<end][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = Color.black
        }
        return result
    }
}
```

- [ ] **Step 4: Run the Markdown tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryMarkdownTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 5: Write the detail pane**

`Roger/UI/Library/LibraryDetailView.swift`:

```swift
import AppKit
import SwiftUI

/// The right column: one item's detail, or a summary of a multi-selection.
struct LibraryDetailView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        let selected = model.selectedItems
        // One branch for both cases, so an edit in progress keeps its state.
        let shown = model.editingItem ?? (selected.count == 1 ? selected.first : nil)
        if let item = shown {
            LibraryItemDetail(item: item, model: model)
                .id(item.id)
        } else if selected.count > 1 {
            ContentUnavailableView(
                "\(selected.count) Items Selected",
                systemImage: "square.stack",
                description: Text("Drag them, copy their paths or move them to the Trash.")
            )
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "books.vertical",
                description: Text("Select an entry to read it here.")
            )
        }
    }
}

/// Header (title, click to rename; metadata; Open Audio; Edit), then the
/// preview or the body editor. Reads the file from disk each time the item
/// is shown or changes.
struct LibraryItemDetail: View {
    @Environment(AppCoordinator.self) private var coordinator
    let item: LibraryItem
    @Bindable var model: LibraryModel

    @State private var document: LibraryDocument?
    @State private var loadError: String?
    @State private var isRenaming = false
    @State private var titleDraft = ""
    @State private var draft = ""
    @State private var editBase: LibraryDocument?
    @State private var showsConflict = false
    @State private var actionError: String?
    @FocusState private var titleFocused: Bool

    private var canEdit: Bool {
        LibraryDocumentEditor.canEdit(item, activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            if model.isEditing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
            } else {
                preview
            }
        }
        .task(id: item) { await load() }
        .onAppear { consumeRenameRequest() }
        .onChange(of: model.renameRequest) { _, _ in consumeRenameRequest() }
        .alert("This file changed on disk", isPresented: $showsConflict) {
            Button("Overwrite", role: .destructive) { save(overwrite: true) }
            Button("Discard my changes") {
                cancelEditing()
                Task { await load() }
            }
        } message: {
            Text("Another app changed it after you started editing. Overwrite it with your text, or discard your changes?")
        }
        .alert("Roger could not do that", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRenaming {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .onTapGesture { startRename() }
                    .help(canEdit ? "Click to rename. The file name stays the same." : "")
            }
            Text(LibraryFormat.metadataLine(for: item))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                audioButton
                Spacer()
                if model.isEditing {
                    Button("Cancel") { cancelEditing() }
                    Button("Save") { save(overwrite: false) }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                } else if canEdit, document != nil {
                    Button("Edit") { startEditing() }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var audioButton: some View {
        if item.audioFiles.count == 1, let url = item.audioFiles.first {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open Audio", systemImage: "play.circle")
            }
        } else if item.audioFiles.count > 1 {
            Menu {
                ForEach(item.audioFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { NSWorkspace.shared.open(url) }
                }
            } label: {
                Label("Open Audio", systemImage: "play.circle")
            }
            .fixedSize()
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if !item.hasMarkdown {
            ContentUnavailableView(
                "Not Transcribed Yet",
                systemImage: "tray.full",
                description: Text("Finalise it under Unfinished in the sidebar.")
            )
        } else if let loadError {
            ContentUnavailableView("Can't Read This File", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if let document {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LibraryMarkdownView(
                        blocks: LibraryMarkdown.blocks(from: document.body, baseURL: item.url.deletingLastPathComponent()),
                        terms: model.searchTerms
                    )
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func load() async {
        guard !model.isEditing, item.hasMarkdown else { return }
        let url = item.url
        do {
            document = try await Task.detached { try LibraryDocument.load(url) }.value
            loadError = nil
        } catch {
            document = nil
            loadError = error.localizedDescription
        }
    }

    private func startEditing() {
        guard let document, canEdit else { return }
        editBase = document
        draft = document.body
        model.editingItem = item
    }

    private func cancelEditing() {
        model.editingItem = nil
        editBase = nil
    }

    private func save(overwrite: Bool) {
        guard let base = editBase else { return }
        do {
            switch try LibraryDocumentEditor.saveBody(draft, of: base, overwrite: overwrite) {
            case .saved:
                cancelEditing()
                Task { await load() }
            case .changedOnDisk:
                showsConflict = true
            case .missing:
                // Stay in edit mode so the text can still be copied.
                actionError = "The file was moved or deleted, so your text was not saved. Copy it before you cancel."
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func consumeRenameRequest() {
        guard model.renameRequest == item.id else { return }
        model.renameRequest = nil
        startRename()
    }

    private func startRename() {
        guard canEdit, !model.isEditing else { return }
        titleDraft = item.title
        isRenaming = true
        titleFocused = true
    }

    private func commitRename() {
        isRenaming = false
        guard titleDraft != item.title else { return }
        do {
            try LibraryDocumentEditor.rename(fileAt: item.url, to: titleDraft)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Headings, paragraphs with inline Markdown and search highlights, and
/// screenshot thumbnails where they appear in the text.
struct LibraryMarkdownView: View {
    let blocks: [LibraryMarkdownBlock]
    let terms: [String]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(LibraryMarkdown.attributed(text, highlighting: terms))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .paragraph(let text):
                    Text(LibraryMarkdown.attributed(text, highlighting: terms))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .image(let alt, let url):
                    LibraryThumbnail(url: url, alt: alt)
                }
            }
        }
    }
}

struct LibraryThumbnail: View {
    let url: URL
    let alt: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 240, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help(alt)
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}
```

- [ ] **Step 6: Show it in the library view**

In `Roger/UI/Library/LibraryView.swift`, replace the detail column body `Text(model.selection.isEmpty ? "No selection" : "\(model.selection.count) selected").foregroundStyle(.secondary)` with:

```swift
            LibraryDetailView(model: model)
```

- [ ] **Step 7: Regenerate, test and check by hand**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. Then in the Debug app:
- A log shows title, "Tue, 13 Oct 2026 · 14:32 · 33 s · ..." and the text; with a search active, the matches are highlighted.
- A meeting with screenshots shows thumbnails between the paragraphs; clicking one opens it.
- "Open Audio" plays a kept log `.m4a`; a meeting offers mic and system.
- Click the title, type a new one, Return: the file name stays, `title:` and the H1 change (check with `head` in Terminal).
- Edit, change a word, Cmd-S: saved, frontmatter unchanged. Edit again, change the file in another editor, Cmd-S: the "This file changed on disk" alert appears; both buttons do what they say.
- While editing, the list cannot be clicked.

- [ ] **Step 8: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/Library/LibraryMarkdown.swift Roger/UI/Library Roger/RogerTests/LibraryMarkdownTests.swift Roger/Roger.xcodeproj
git commit -m "feat: library detail pane with preview, rename and edit"
```

---
### Task 9: Actions: drag, copy path, open, reveal and Trash

**Files:**
- Create: `Roger/Services/Library/LibraryActions.swift`
- Create: `Roger/UI/Library/LibraryCommands.swift`
- Modify: `Roger/UI/Library/LibraryListView.swift`
- Modify: `Roger/App/AppCoordinator.swift` (`refreshPendingMeetingSessions()` becomes internal)
- Test: `Roger/RogerTests/LibraryActionsTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryItem` (Task 1); `LibraryPath` (Task 3); `LibraryModel` (`results`, `selection`, `selectedItems`, `renameRequest`, `isEditing`) (Task 6); `LibraryListView` (Task 7); `MeetingRecordingService.activeSessionFolder` (Task 6); existing `MeetingSessionScanner.isSessionFolder(_:)`, `LibraryLayout.kindFolder(_:)`, `AppState.extraScanFolders`.
- Produces:
  - `enum LibraryActions { static func fileURLs(for: [LibraryItem]) -> [URL]; static func pathsText(for: [LibraryItem]) -> String; static func folderURLs(for: [LibraryItem]) -> [URL]; static func folderPathsText(for: [LibraryItem]) -> String; struct TrashPlan: Equatable { var urls: [URL]; var meetingFolderCount: Int; var skipped: [LibraryItem]; var needsConfirmation: Bool }; static func trashPlan(for: [LibraryItem], protectedFolders: [URL], activeSessionFolder: URL?) -> TrashPlan; @discardableResult static func moveToTrash(_ urls: [URL], trash: (URL) throws -> Void = ...) -> [URL] }` (returns the URLs that failed).
  - `@MainActor struct LibraryCommands { let model: LibraryModel; let coordinator: AppCoordinator; func items(_: Set<LibraryItem.ID>) -> [LibraryItem]; func open(_:); func reveal(_:); func copyPaths(_:); func copyFolderPaths(_:); func trashPlan(for:) -> LibraryActions.TrashPlan }`
  - `AppCoordinator.refreshPendingMeetingSessions()` is internal (was `private`), so the library can refresh the Unfinished list after trashing a meeting.

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/LibraryActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct LibraryActionsTests {
    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    @Test func pathsAndFolders() {
        let a = LibraryFixtures.item("a")
        let b = LibraryFixtures.item("b")
        let meeting = LibraryFixtures.item("transcript", kind: .meeting, folder: "/RogerFixtures/Meetings/2026/10/s")
        #expect(LibraryActions.pathsText(for: [a, meeting])
            == "/RogerFixtures/Logs/2026/10/a.md\n/RogerFixtures/Meetings/2026/10/s/transcript.md")
        #expect(LibraryActions.folderURLs(for: [a, b, meeting]).map(\.path)
            == ["/RogerFixtures/Logs/2026/10", "/RogerFixtures/Meetings/2026/10/s"])
        #expect(LibraryActions.folderPathsText(for: [a, b]) == "/RogerFixtures/Logs/2026/10")
    }

    @Test func logGoesWithItsAudioAndNothingElse() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let month = root.appendingPathComponent("Logs/2026/10", isDirectory: true)
        try touch(month.appendingPathComponent("x.md"))
        try touch(month.appendingPathComponent("x.m4a"))
        try touch(month.appendingPathComponent("y.md"))
        let item = LibraryFixtures.item("x", folder: month.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [root], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["x.md", "x.m4a"])
        #expect(!plan.needsConfirmation)
    }

    @Test func transcriptLeavesItsSourceMediaAlone() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let media = root.appendingPathComponent("talk.mp4")
        try touch(media)
        try touch(root.appendingPathComponent("talk.mp4.md"))
        let item = LibraryFixtures.item("talk.mp4", kind: .transcript, folder: root.path, audio: [media])
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["talk.mp4.md"])
    }

    @Test func meetingGoesAsWholeFolderAfterConfirmation() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("Meetings/2026/10/2026-10-13 09-00", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic.m4a"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(
            for: [item],
            protectedFolders: [root, root.appendingPathComponent("Meetings")],
            activeSessionFolder: nil
        )
        #expect(plan.urls.map(\.lastPathComponent) == ["2026-10-13 09-00"])
        #expect(plan.meetingFolderCount == 1)
        #expect(plan.needsConfirmation)
    }

    @Test func unfinishedMeetingGoesAsFolder() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("s", isDirectory: true)
        try touch(session.appendingPathComponent("mic-001.caf"))
        var item = LibraryFixtures.item("x", kind: .meeting, folder: session.path, unfinished: true)
        item.url = session
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["s"])
        #expect(plan.needsConfirmation)
    }

    @Test func meetingFileOutsideASessionMovesOnlyTheFile() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let month = root.appendingPathComponent("Transcripts/2026/10", isDirectory: true)
        try touch(month.appendingPathComponent("odd.md"))
        try touch(month.appendingPathComponent("other.md"))
        let item = LibraryFixtures.item("odd", kind: .meeting, folder: month.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: nil)
        #expect(plan.urls.map(\.lastPathComponent) == ["odd.md"])
        #expect(!plan.needsConfirmation)
    }

    @Test func protectedFoldersAreNeverTrashed() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        // A session folder that is itself an extra scan folder.
        let extra = root.appendingPathComponent("Roger Recordings", isDirectory: true)
        try touch(extra.appendingPathComponent("transcript.md"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: extra.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [extra], activeSessionFolder: nil)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])

        // A session folder that contains the library root.
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        try touch(outer.appendingPathComponent("transcript.md"))
        let library = outer.appendingPathComponent("Roger", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let outerItem = LibraryFixtures.item("transcript", kind: .meeting, folder: outer.path)
        #expect(LibraryActions.trashPlan(for: [outerItem], protectedFolders: [library], activeSessionFolder: nil).urls.isEmpty)
    }

    @Test func activeSessionIsSkipped() throws {
        let root = try TempFolder.make()
        defer { TempFolder.remove(root) }
        let session = root.appendingPathComponent("s", isDirectory: true)
        try touch(session.appendingPathComponent("transcript.md"))
        try touch(session.appendingPathComponent("mic-001.caf"))
        let item = LibraryFixtures.item("transcript", kind: .meeting, folder: session.path)
        let plan = LibraryActions.trashPlan(for: [item], protectedFolders: [], activeSessionFolder: session)
        #expect(plan.urls.isEmpty)
        #expect(plan.skipped == [item])
    }

    @Test func moveToTrashReportsFailuresAndTriesEveryURL() {
        let a = URL(fileURLWithPath: "/RogerFixtures/a.md")
        let b = URL(fileURLWithPath: "/RogerFixtures/b.md")
        var tried: [URL] = []
        let failed = LibraryActions.moveToTrash([a, b]) { url in
            tried.append(url)
            if url == a { throw CocoaError(.fileWriteNoPermission) }
        }
        #expect(tried == [a, b])
        #expect(failed == [a])
    }
}
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryActionsTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'LibraryActions' in scope".

- [ ] **Step 3: Write the actions**

`Roger/Services/Library/LibraryActions.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "LibraryActions")

/// The file side of the library actions. Nothing here deletes: removal
/// goes through the Trash, and `trashPlan` decides exactly what may go.
enum LibraryActions {
    /// The Markdown files (meetings: `transcript.md`). An unfinished meeting
    /// without a transcript gives its session folder. Used for Drag, Copy
    /// Path, Open and Reveal in Finder.
    static func fileURLs(for items: [LibraryItem]) -> [URL] {
        items.map(\.url)
    }

    /// POSIX paths, one per line, ready to paste into an agent or a terminal.
    static func pathsText(for items: [LibraryItem]) -> String {
        fileURLs(for: items).map(\.path).joined(separator: "\n")
    }

    /// Meeting session folders, or the folder holding a log or transcript
    /// (its month folder in the library). Each folder once, in order.
    static func folderURLs(for items: [LibraryItem]) -> [URL] {
        var seen = Set<String>()
        return items.map(\.folderURL).filter { seen.insert($0.path).inserted }
    }

    static func folderPathsText(for items: [LibraryItem]) -> String {
        folderURLs(for: items).map(\.path).joined(separator: "\n")
    }

    struct TrashPlan: Equatable {
        var urls: [URL] = []
        /// Whole meeting folders in `urls`; they need a confirmation.
        var meetingFolderCount = 0
        /// Items that stay: the active meeting, protected folders, nothing to move.
        var skipped: [LibraryItem] = []
        var needsConfirmation: Bool { meetingFolderCount > 0 }
    }

    /// What Move to Trash moves:
    /// - a log: its `.md` and the `.m4a` with the same name next to it;
    /// - a file transcript: its `.md` only, never the source media;
    /// - a meeting: its whole session folder, but only when the item is
    ///   that folder's `transcript.md` (or the folder itself when
    ///   unfinished), the folder is a session folder, and it neither is nor
    ///   contains one of `protectedFolders` (library root, kind folders,
    ///   extra scan folders); otherwise the meeting stays;
    /// - nothing inside `activeSessionFolder` (recording or finalising).
    static func trashPlan(for items: [LibraryItem], protectedFolders: [URL], activeSessionFolder: URL?) -> TrashPlan {
        let protected = protectedFolders.map { LibraryPath.canonical($0) }
        let active = activeSessionFolder.map { LibraryPath.canonical($0) }
        var plan = TrashPlan()
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(LibraryPath.canonical(url)).inserted { plan.urls.append(url) }
        }
        for item in items {
            let folder = LibraryPath.canonical(item.folderURL)
            if let active, folder == active || LibraryPath.isPath(LibraryPath.canonical(item.url), inside: active) {
                plan.skipped.append(item)
                continue
            }
            if item.kind == .meeting, ownsSessionFolder(item, folder: folder) {
                let safe = MeetingSessionScanner.isSessionFolder(item.folderURL)
                    && !protected.contains { LibraryPath.isPath($0, inside: folder) }
                if safe {
                    add(item.folderURL)
                    plan.meetingFolderCount += 1
                } else {
                    plan.skipped.append(item)
                }
                continue
            }
            guard item.hasMarkdown else {
                plan.skipped.append(item)
                continue
            }
            add(item.url)
            if item.kind == .log {
                let audio = item.url.deletingPathExtension().appendingPathExtension("m4a")
                if FileManager.default.fileExists(atPath: audio.path) { add(audio) }
            }
        }
        return plan
    }

    /// Moves each URL to the Trash and returns the ones that failed. Tries
    /// every URL even after a failure.
    @discardableResult
    static func moveToTrash(
        _ urls: [URL],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> [URL] {
        var failed: [URL] = []
        for url in urls {
            do {
                try trash(url)
            } catch {
                logger.error("Could not move \(url.lastPathComponent, privacy: .public) to the Trash: \(error.localizedDescription, privacy: .public)")
                failed.append(url)
            }
        }
        return failed
    }

    /// The item is its session's `transcript.md`, or (unfinished) the session folder itself.
    private static func ownsSessionFolder(_ item: LibraryItem, folder: String) -> Bool {
        if item.hasMarkdown {
            return item.url.lastPathComponent == "transcript.md"
                && LibraryPath.canonical(item.url.deletingLastPathComponent()) == folder
        }
        return LibraryPath.canonical(item.url) == folder
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/LibraryActionsTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 9 tests passed.

- [ ] **Step 5: Write the AppKit commands**

`Roger/UI/Library/LibraryCommands.swift`:

```swift
import AppKit

/// AppKit side of the library actions, used by the list, its context menu
/// and the toolbar.
@MainActor
struct LibraryCommands {
    let model: LibraryModel
    let coordinator: AppCoordinator

    func items(_ ids: Set<LibraryItem.ID>) -> [LibraryItem] {
        model.results.filter { ids.contains($0.id) }
    }

    /// Default app for `.md`. An unfinished meeting opens its folder in Finder.
    func open(_ items: [LibraryItem]) {
        for item in items {
            if item.hasMarkdown {
                NSWorkspace.shared.open(item.url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
            }
        }
    }

    func reveal(_ items: [LibraryItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(LibraryActions.fileURLs(for: items))
    }

    func copyPaths(_ items: [LibraryItem]) {
        copy(LibraryActions.pathsText(for: items))
    }

    func copyFolderPaths(_ items: [LibraryItem]) {
        copy(LibraryActions.folderPathsText(for: items))
    }

    func trashPlan(for items: [LibraryItem]) -> LibraryActions.TrashPlan {
        let layout = coordinator.appState.libraryLayout
        let protected = [layout.root]
            + LibraryLayout.Kind.allCases.map { layout.kindFolder($0) }
            + coordinator.appState.extraScanFolders
        return LibraryActions.trashPlan(
            for: items,
            protectedFolders: protected,
            activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder
        )
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

- [ ] **Step 6: Wire the actions into the list**

First, in `Roger/App/AppCoordinator.swift`, change `private func refreshPendingMeetingSessions()` to `func refreshPendingMeetingSessions()` and add above it:

```swift
    /// Also called by the library after it moved a meeting to the Trash, so
    /// the popover banner and the Unfinished list drop it right away.
```

Then:

In `Roger/UI/Library/LibraryListView.swift`, in `struct LibraryListView`:

1. Add below `@Bindable var model: LibraryModel`:

```swift
    @State private var pendingTrash: LibraryActions.TrashPlan?
    @State private var message: String?

    private var commands: LibraryCommands {
        LibraryCommands(model: model, coordinator: coordinator)
    }
```

2. In `rows(_:)`, add after `.tag(item.id)`:

```swift
                .onDrag {
                    NSItemProvider(object: item.url as NSURL)
                }
```

3. Insert these modifiers between `.listStyle(.inset)` and `.disabled(model.isEditing)`:

```swift
        .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
            let items = commands.items(ids)
            if !items.isEmpty {
                Button("Open") { commands.open(items) }
                Button("Reveal in Finder") { commands.reveal(items) }
                Divider()
                Button("Copy Path") { commands.copyPaths(items) }
                Button("Copy Folder Path") { commands.copyFolderPaths(items) }
                if items.count == 1, let item = items.first, item.hasMarkdown {
                    Divider()
                    Button("Rename…") {
                        model.selection = [item.id]
                        model.renameRequest = item.id
                    }
                }
                Divider()
                Button("Move to Trash") { requestTrash(items) }
            }
        } primaryAction: { ids in
            // Return and double-click.
            commands.open(commands.items(ids))
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            // Cmd-Backspace, only while the list has focus, so it never
            // fires in the search field or the editor.
            guard press.modifiers.contains(.command), !model.selection.isEmpty, !model.isEditing else { return .ignored }
            requestTrash(model.selectedItems)
            return .handled
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    commands.copyPaths(model.selectedItems)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the paths of the selected files (⇧⌘C)")
                .disabled(model.selection.isEmpty)

                Button {
                    commands.reveal(model.selectedItems)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
                .disabled(model.selection.isEmpty)

                Button {
                    requestTrash(model.selectedItems)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .help("Move to Trash (⌘⌫)")
                .disabled(model.selection.isEmpty || model.isEditing)
            }
        }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let plan = pendingTrash { runTrash(plan) }
                pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("The whole meeting folder goes to the Trash, with its audio, screenshots and transcript. You can put it back from the Trash.")
        }
        .alert("Library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
```

4. Add these methods to `LibraryListView`:

```swift
    private var trashTitle: String {
        guard let plan = pendingTrash else { return "" }
        let count = plan.urls.count
        if count == plan.meetingFolderCount {
            return count == 1 ? "Move this meeting to the Trash?" : "Move \(count) meetings to the Trash?"
        }
        return "Move \(count) items to the Trash?"
    }

    /// Logs and transcripts go straight to the Trash; a plan with meeting
    /// folders asks first.
    private func requestTrash(_ items: [LibraryItem]) {
        let plan = commands.trashPlan(for: items)
        if plan.urls.isEmpty {
            if !plan.skipped.isEmpty {
                message = "Roger left this where it is. It does not move a meeting that is being recorded or finalised, or a folder the library depends on."
            }
            return
        }
        if plan.needsConfirmation {
            pendingTrash = plan
        } else {
            runTrash(plan)
        }
    }

    private func runTrash(_ plan: LibraryActions.TrashPlan) {
        let failed = LibraryActions.moveToTrash(plan.urls)
        model.selection = []
        if plan.meetingFolderCount > 0 {
            // A trashed unfinished meeting must leave the popover banner and
            // the Unfinished list now, not after the next recording.
            coordinator.refreshPendingMeetingSessions()
        }
        if !failed.isEmpty {
            message = "Some files could not be moved to the Trash: \(failed.map(\.lastPathComponent).joined(separator: ", "))."
        } else if !plan.skipped.isEmpty {
            message = "Some items stayed where they are. Roger does not move a meeting that is being recorded or finalised, or a folder the library depends on."
        }
    }
```

The index notices the moved files through FSEvents and drops them from the list.

- [ ] **Step 7: Build, test and check by hand**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "warning:|error:|BUILD" | tail -20
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`. Then in the Debug app:
- Drag a log into Terminal: its path is inserted. Drag a meeting into Claude Code: `transcript.md` is attached. Select several rows and drag one of them: SwiftUI on macOS 15 has no multi-item `List` drag API (`dragContainer` needs macOS 26), so the drag may carry only that row. That is accepted; Copy Path is the multi-file hand-off. Say in your task report what you saw.
- Select three items, Cmd-Shift-C, paste in TextEdit: three paths, one per line. Copy Folder Path on a log gives its month folder.
- Return and double-click open the `.md` in the default app. Reveal in Finder selects the files.
- Cmd-Backspace on a log moves it and its `.m4a` to the Trash without asking. On a meeting it asks first, then the whole folder goes. Cmd-Backspace in the search field deletes text and moves nothing.
- During a meeting recording, try to trash its unfinished entry: Roger refuses with the message.
- Trash an unfinished meeting (one listed under Unfinished): its row and the popover banner disappear at once.
- Context menu Rename… starts renaming in the detail pane.

- [ ] **Step 8: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/Library/LibraryActions.swift Roger/UI/Library Roger/App/AppCoordinator.swift Roger/RogerTests/LibraryActionsTests.swift Roger/Roger.xcodeproj
git commit -m "feat: drag, copy path, reveal and trash library items"
```

---
### Task 10: A retry keeps edited segment files (#8)

**Files:**
- Modify: `Roger/Services/MeetingRecording/MeetingArchiveMerge.swift` (shared `moveAside`)
- Modify: `Roger/Services/MeetingRecording/MeetingTranscriptWriter.swift` (use `moveAside`)
- Modify: `Roger/Services/MeetingRecording/MeetingSegmentWriter.swift` (never overwrite or delete a non-draft segment)
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (comment only, around line 604)
- Test: `Roger/RogerTests/MeetingSegmentWriterTests.swift`
- Test: `Roger/RogerTests/MeetingArchiveMergeTests.swift` (add one test)
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `LibraryFrontmatterParser.parse(_:)` (Task 1); existing `MeetingArchiveMerge.uniqueSibling(of:label:)`, `MeetingSegmentWriter.fileName(chunkStart:)`.
- Produces:
  - `MeetingArchiveMerge.moveAside(_ url: URL, label: String = "previous") throws -> URL` (`@discardableResult`): moves `url` to its first free `<stem>.<label>[ N].<ext>` sibling. The one helper for `transcript.previous.md`, segment `.previous.md` files and archive `.previous.m4a` files.
  - `MeetingSegmentWriter.isDraft(_ url: URL) -> Bool`, `MeetingSegmentWriter.setAsideUnlessDraft(_ url: URL) throws`. `write(...)` and `removeIfExists(chunkStart:folder:)` keep their signatures.

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/MeetingSegmentWriterTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct MeetingSegmentWriterTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func write(_ folder: URL, _ text: String, provisional: Bool) throws -> URL {
        try #require(try MeetingSegmentWriter.write(
            paragraphs: [.init(speaker: "Me", startTime: 0, text: text)],
            sessionStartedAt: start,
            chunkStart: start,
            chunkEnd: start.addingTimeInterval(30),
            folder: folder,
            provisional: provisional
        ))
    }

    private func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func previous(_ url: URL, _ suffix: String = "") -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".previous\(suffix).md")
    }

    @Test func draftIsReplaced() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Live words", provisional: true)
        _ = try write(folder, "Final words", provisional: false)
        #expect(try names(folder) == [url.lastPathComponent])
        let text = try read(url)
        #expect(text.contains("Final words"))
        #expect(text.contains("\nstatus: stable\n"))
    }

    @Test func stableSegmentIsMovedAsideBeforeARetry() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false)
        try (try read(url) + "My own note\n").write(to: url, atomically: true, encoding: .utf8)
        _ = try write(folder, "Retry words", provisional: false)
        #expect(try read(previous(url)).contains("My own note"))
        #expect(try read(url).contains("Retry words"))
    }

    @Test func anExistingPreviousFileIsNeverOverwritten() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false)
        try "older copy".write(to: previous(url), atomically: true, encoding: .utf8)
        try (try read(url) + "My own note\n").write(to: url, atomically: true, encoding: .utf8)
        _ = try write(folder, "Retry words", provisional: false)
        #expect(try read(previous(url)) == "older copy")
        #expect(try read(previous(url, " 1")).contains("My own note"))
    }

    @Test func aHandWrittenFileWithoutFrontmatterIsKept() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = folder.appendingPathComponent(MeetingSegmentWriter.fileName(chunkStart: start))
        try "my notes".write(to: url, atomically: true, encoding: .utf8)
        _ = try write(folder, "Retry words", provisional: false)
        #expect(try read(previous(url)) == "my notes")
    }

    @Test func anEmptyRangeKeepsAStableSegment() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = try write(folder, "Final words", provisional: false)
        MeetingSegmentWriter.removeIfExists(chunkStart: start, folder: folder)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try read(previous(url)).contains("Final words"))
    }

    @Test func anEmptyRangeDropsADraft() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        _ = try write(folder, "Live words", provisional: true)
        MeetingSegmentWriter.removeIfExists(chunkStart: start, folder: folder)
        #expect(try names(folder).isEmpty)
    }
}
```

Add to `Roger/RogerTests/MeetingArchiveMergeTests.swift`, inside the existing suite:

```swift
    @Test func moveAsidePicksTheNextFreeName() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        let url = folder.appendingPathComponent("transcript.md")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        #expect(try MeetingArchiveMerge.moveAside(url).lastPathComponent == "transcript.previous.md")
        try "two".write(to: url, atomically: true, encoding: .utf8)
        #expect(try MeetingArchiveMerge.moveAside(url).lastPathComponent == "transcript.previous 1.md")
        #expect(try String(contentsOf: folder.appendingPathComponent("transcript.previous.md"), encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
```

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/MeetingSegmentWriterTests -only-testing:RogerTests/MeetingArchiveMergeTests 2>&1 | tail -20
```

Expected: build fails with "type 'MeetingArchiveMerge' has no member 'moveAside'".

- [ ] **Step 3: Add the shared helper**

In `Roger/Services/MeetingRecording/MeetingArchiveMerge.swift`, add below `uniqueSibling(of:label:)`:

```swift
    /// Moves `url` to its first free `<stem>.<label>.<ext>` sibling
    /// (`<stem>.<label> 1.<ext>` …) and returns where it went. Never
    /// overwrites: `moveItem` fails rather than replace an existing file.
    /// The one helper for `transcript.previous.md`, segment
    /// `<name>.previous.md` files and `mic.previous.m4a` style archives.
    @discardableResult
    static func moveAside(_ url: URL, label: String = "previous") throws -> URL {
        let target = uniqueSibling(of: url, label: label)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
```

In `settle(archive:encoded:keepEncoded:)`, replace

```swift
        let previous = uniqueSibling(of: archive, label: "previous")
        try fm.moveItem(at: archive, to: previous)
```

with

```swift
        let previous = try moveAside(archive)
```

- [ ] **Step 4: Use it for the transcript**

In `Roger/Services/MeetingRecording/MeetingTranscriptWriter.swift`, in `write(paragraphs:metadata:markers:)`, replace

```swift
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = MeetingArchiveMerge.uniqueSibling(of: url, label: "previous")
            try FileManager.default.moveItem(at: url, to: previous)
        }
```

with

```swift
        if FileManager.default.fileExists(atPath: url.path) {
            try MeetingArchiveMerge.moveAside(url)
        }
```

- [ ] **Step 5: Never overwrite or delete a non-draft segment**

Replace the whole content of `Roger/Services/MeetingRecording/MeetingSegmentWriter.swift` with:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "MeetingSegmentWriter")

/// Writes one chronological transcript segment ("<yyyy-MM-dd HH-mm-ss>.md")
/// into the session folder: the audio between two screenshot checkpoints.
/// Segment files sort between the screenshots around them, so the folder
/// reads as an alternating md/png timeline. Live checkpoint writes carry
/// `status: draft`; finalisation rewrites every segment from the full-audio
/// pass under the same names with `status: stable`.
///
/// Only drafts are replaced or deleted. Any other segment (stable from an
/// earlier finalisation and maybe edited, or without readable frontmatter)
/// is first moved aside to `<name>.previous.md` (`<name>.previous 1.md` …),
/// so a retry never loses edits.
enum MeetingSegmentWriter {
    /// Returns nil without writing when `paragraphs` is empty: a screenshot
    /// with no speech before it needs no transcript file. `chunkEnd` is the
    /// capture time of the screenshot that closes the segment, or the end of
    /// the recording for the last one. Throws without writing when an
    /// existing non-draft segment cannot be moved aside.
    @discardableResult
    static func write(
        paragraphs: [MeetingTranscriptMerger.Paragraph],
        sessionStartedAt: Date,
        chunkStart: Date,
        chunkEnd: Date,
        folder: URL,
        provisional: Bool
    ) throws -> URL? {
        guard !paragraphs.isEmpty else { return nil }
        let meetingTitle = "Meeting \(MeetingTranscriptWriter.displayDate(sessionStartedAt))"
        var fm = TranscriptFrontmatter(
            title: "\(meetingTitle), from \(timeOfDay(chunkStart))",
            description: "Part of a meeting transcript: what was said between two slide screenshots.",
            tags: ["meeting", "segment"],
            sourceDate: chunkStart,
            temporalConfidence: .explicit,
            status: provisional ? "draft" : "stable"
        )
        fm.add("started_at", date: chunkStart)
        fm.add("ended_at", date: max(chunkStart, chunkEnd))
        fm.add("meeting", "transcript.md")
        var out = fm.render()
        for paragraph in paragraphs {
            out += MeetingTranscriptWriter.paragraphMarkdown(paragraph, sessionStart: sessionStartedAt)
        }
        let url = folder.appendingPathComponent(fileName(chunkStart: chunkStart))
        try setAsideUnlessDraft(url)
        try out.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Wrote segment \(url.lastPathComponent, privacy: .public) (\(paragraphs.count) paragraphs\(provisional ? ", provisional" : ""))")
        return url
    }

    /// True when the file is a live draft (`status: draft`) that finalisation may replace.
    static func isDraft(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return LibraryFrontmatterParser.parse(text)?.scalars["status"] == "draft"
    }

    /// Moves an existing segment that is not a draft aside. Throws when that
    /// fails, so the caller does not write over it.
    static func setAsideUnlessDraft(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), !isDraft(url) else { return }
        let aside = try MeetingArchiveMerge.moveAside(url)
        logger.notice("Kept \(url.lastPathComponent, privacy: .public) as \(aside.lastPathComponent, privacy: .public)")
    }

    private static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func fileName(chunkStart: Date) -> String {
        MeetingCheckpointStore.stem(for: chunkStart) + ".md"
    }

    /// Finalisation cleanup for a segment whose range turned out empty: a
    /// draft is deleted, anything else is moved aside.
    static func removeIfExists(chunkStart: Date, folder: URL) {
        let url = folder.appendingPathComponent(fileName(chunkStart: chunkStart))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if isDraft(url) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try setAsideUnlessDraft(url)
        } catch {
            logger.warning("Could not move \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

In `Roger/Services/MeetingRecording/MeetingRecordingService.swift`, replace the comment

```swift
        // Screenshot checkpoints: rewrite every segment md from this
        // authoritative full pass (overwriting the provisional live ones)
        // and weave inline image references into transcript.md.
```

with

```swift
        // Screenshot checkpoints: rewrite every segment md from this
        // authoritative full pass (replacing the live drafts; a segment that
        // is already stable, maybe edited, is moved aside to
        // <name>.previous.md first) and weave inline image references into
        // transcript.md.
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`, including the 6 new segment tests, `moveAsidePicksTheNextFreeName` and the existing `MeetingTranscriptWriterTests.existingTranscriptIsMovedAsideNotOverwritten`.

- [ ] **Step 7: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/MeetingRecording Roger/RogerTests/MeetingSegmentWriterTests.swift Roger/RogerTests/MeetingArchiveMergeTests.swift Roger/Roger.xcodeproj
git commit -m "fix: keep edited segment files when a meeting is retried"
```

---

### Task 11: Extra files after a retry (#9)

**Files:**
- Create: `Roger/Services/MeetingRecording/MeetingExtraFiles.swift`
- Create: `Roger/UI/Library/LibraryExtraFilesSection.swift`
- Modify: `Roger/Services/MeetingRecording/MeetingTranscriptWriter.swift` (`sources` lists extra audio)
- Modify: `Roger/Models/MeetingRecordingError.swift` (new case and decision)
- Modify: `Roger/Services/MeetingRecording/MeetingRecordingService.swift` (`encodeTrack` returns the leftover URL; final state)
- Modify: `Roger/UI/Library/LibraryDetailView.swift` (show the section)
- Test: `Roger/RogerTests/MeetingExtraFilesTests.swift`
- Test: `Roger/RogerTests/MeetingRecordingErrorTests.swift`
- Regenerated: `Roger/Roger.xcodeproj`

**Interfaces:**
- Consumes: `MeetingArchiveMerge.moveAside` naming (Task 10); `LibraryActions.moveToTrash` (Task 9); `LibraryDocumentEditor.canEdit` (Task 5); `LibraryItemDetail` (Task 8); existing `TranscriptFrontmatter.Source`.
- Produces:
  - `enum MeetingExtraFiles { enum Kind: String, CaseIterable, Sendable { case micLeftover = "mic-leftover", systemLeftover = "system-leftover", micPrevious = "mic-previous", systemPrevious = "system-previous", transcriptPrevious = "transcript-previous", segmentPrevious = "segment-previous"; var isAudio: Bool }; struct File: Equatable, Sendable { let url: URL; let kind: Kind; let number: Int }; static func classify(_ name: String) -> (kind: Kind, number: Int)?; static func find(in folder: URL) -> [File]; static func audioSources(in folder: URL) -> [TranscriptFrontmatter.Source] }`
  - `MeetingRecordingError.audioSetAside(files: [String])`, `static func afterFinalisation(micNeedsRetry: Bool, systemNeedsRetry: Bool, setAside: [String]) -> MeetingRecordingError?`, `static func listed(_ names: [String]) -> String`
  - `struct LibraryExtraFilesSection: View { let item: LibraryItem }`

- [ ] **Step 1: Write the failing tests**

`Roger/RogerTests/MeetingExtraFilesTests.swift`:

```swift
import Foundation
import Testing
@testable import Roger

struct MeetingExtraFilesTests {
    private func touch(_ folder: URL, _ names: [String]) throws {
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
    }

    @Test func classifiesNames() {
        #expect(MeetingExtraFiles.classify("mic.leftover.m4a")?.kind == .micLeftover)
        #expect(MeetingExtraFiles.classify("mic.leftover.m4a")?.number == 0)
        #expect(MeetingExtraFiles.classify("mic.leftover 2.m4a")?.number == 2)
        #expect(MeetingExtraFiles.classify("system.leftover.m4a")?.kind == .systemLeftover)
        #expect(MeetingExtraFiles.classify("mic.previous 1.m4a")?.kind == .micPrevious)
        #expect(MeetingExtraFiles.classify("system.previous.m4a")?.kind == .systemPrevious)
        #expect(MeetingExtraFiles.classify("transcript.previous 1.md")?.kind == .transcriptPrevious)
        #expect(MeetingExtraFiles.classify("2026-10-13 09-05-00.previous.md")?.kind == .segmentPrevious)
        for name in ["mic.m4a", "system.m4a", "transcript.md", "mic-001.caf", "notes.txt",
                     "mic.leftover x.m4a", "speaker.leftover.m4a", ".previous.md", "markers.json"] {
            #expect(MeetingExtraFiles.classify(name) == nil, "\(name)")
        }
    }

    @Test func findsAndOrdersExtraFiles() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, [
            "transcript.md", "mic.m4a", "system.m4a",
            "2026-10-13 09-05-00.previous.md", "transcript.previous.md",
            "system.previous.m4a", "mic.leftover 1.m4a", "mic.leftover.m4a",
        ])
        #expect(MeetingExtraFiles.find(in: folder).map(\.url.lastPathComponent) == [
            "mic.leftover.m4a", "mic.leftover 1.m4a", "system.previous.m4a",
            "transcript.previous.md", "2026-10-13 09-05-00.previous.md",
        ])
    }

    @Test func audioSourcesGetNumberedIDs() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, ["mic.leftover 1.m4a", "mic.leftover.m4a", "system.previous.m4a", "transcript.previous.md"])
        #expect(MeetingExtraFiles.audioSources(in: folder).map { "\($0.id)=\($0.resource)" } == [
            "mic-leftover=mic.leftover.m4a",
            "mic-leftover-2=mic.leftover 1.m4a",
            "system-previous=system.previous.m4a",
        ])
    }

    @Test func transcriptListsExtraAudioInSources() throws {
        let folder = try TempFolder.make()
        defer { TempFolder.remove(folder) }
        try touch(folder, ["mic.m4a", "mic.leftover.m4a"])
        let url = try MeetingTranscriptWriter.write(
            paragraphs: [],
            metadata: .init(
                session: MeetingSession(id: UUID(), folder: folder, startedAt: Date(timeIntervalSince1970: 1_790_000_000)),
                durationSeconds: 60, speakerCount: 1, language: nil, micPresent: true, systemPresent: false,
                audioKept: true, diarized: false, diarizationFailed: false, micAudioFailed: true
            )
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("  - { id: mic, resource: \"mic.m4a\" }\n  - { id: mic-leftover, resource: \"mic.leftover.m4a\" }\n"))
    }
}
```

`Roger/RogerTests/MeetingRecordingErrorTests.swift`:

```swift
import Testing
@testable import Roger

struct MeetingRecordingErrorTests {
    @Test func keptChunksAskForARetry() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: true, systemNeedsRetry: false, setAside: ["mic.leftover.m4a"])
        guard case .trackAudioFailed(let mic, let system)? = error else {
            Issue.record("expected trackAudioFailed, got \(String(describing: error))")
            return
        }
        #expect(mic && !system)
        #expect(error?.errorDescription?.contains("Try again") == true)
    }

    @Test func audioSetAsideSaysWhereItIs() {
        let error = MeetingRecordingError.afterFinalisation(micNeedsRetry: false, systemNeedsRetry: false, setAside: ["mic.leftover.m4a"])
        #expect(error?.errorDescription == "Some audio could not be merged. It is saved as mic.leftover.m4a in the meeting folder.")
        #expect(error?.errorDescription?.contains("Try again") == false)
    }

    @Test func severalFilesAreListedWithoutOxfordComma() {
        let error = MeetingRecordingError.afterFinalisation(
            micNeedsRetry: false, systemNeedsRetry: false,
            setAside: ["mic.leftover.m4a", "system.leftover.m4a"]
        )
        #expect(error?.errorDescription == "Some audio could not be merged. It is saved as mic.leftover.m4a and system.leftover.m4a in the meeting folder.")
        #expect(MeetingRecordingError.listed(["a", "b", "c"]) == "a, b and c")
    }

    @Test func nothingWrongIsNoError() {
        #expect(MeetingRecordingError.afterFinalisation(micNeedsRetry: false, systemNeedsRetry: false, setAside: []) == nil)
    }
}
```

`MeetingRecordingError` is not `Equatable`; `== nil` works on any optional.

- [ ] **Step 2: Regenerate and run the tests to verify they fail**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' -only-testing:RogerTests/MeetingExtraFilesTests -only-testing:RogerTests/MeetingRecordingErrorTests 2>&1 | tail -20
```

Expected: build fails with "cannot find 'MeetingExtraFiles' in scope".

- [ ] **Step 3: Write the extra-file scanner**

`Roger/Services/MeetingRecording/MeetingExtraFiles.swift`:

```swift
import Foundation

/// Files a retry can leave in a meeting folder: leftover and previous
/// audio archives, the previous transcript and previous segments. Nothing
/// here moves or deletes them.
enum MeetingExtraFiles {
    enum Kind: String, CaseIterable, Sendable {
        case micLeftover = "mic-leftover"
        case systemLeftover = "system-leftover"
        case micPrevious = "mic-previous"
        case systemPrevious = "system-previous"
        case transcriptPrevious = "transcript-previous"
        case segmentPrevious = "segment-previous"

        var isAudio: Bool {
            switch self {
            case .micLeftover, .systemLeftover, .micPrevious, .systemPrevious: return true
            case .transcriptPrevious, .segmentPrevious: return false
            }
        }
    }

    struct File: Equatable, Sendable {
        let url: URL
        let kind: Kind
        /// 0 for `x.leftover.m4a`, N for `x.leftover N.m4a`.
        let number: Int
    }

    /// Kind and number of an extra file name, or nil.
    static func classify(_ name: String) -> (kind: Kind, number: Int)? {
        if case let (stem, number)? = labeled(name, label: "leftover", ext: "m4a") {
            switch stem {
            case "mic": return (.micLeftover, number)
            case "system": return (.systemLeftover, number)
            default: return nil
            }
        }
        if case let (stem, number)? = labeled(name, label: "previous", ext: "m4a") {
            switch stem {
            case "mic": return (.micPrevious, number)
            case "system": return (.systemPrevious, number)
            default: return nil
            }
        }
        if case let (stem, number)? = labeled(name, label: "previous", ext: "md") {
            return (stem == "transcript" ? .transcriptPrevious : .segmentPrevious, number)
        }
        return nil
    }

    /// Extra files in `folder`, ordered by kind, then number.
    static func find(in folder: URL) -> [File] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let order = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return names
            .compactMap { name in
                classify(name).map { File(url: folder.appendingPathComponent(name), kind: $0.kind, number: $0.number) }
            }
            .sorted { a, b in
                if a.kind != b.kind { return order[a.kind, default: 0] < order[b.kind, default: 0] }
                if a.number != b.number { return a.number < b.number }
                return a.url.lastPathComponent < b.url.lastPathComponent
            }
    }

    /// `sources` entries for the extra audio files, so agents see them:
    /// ids `mic-leftover`, `mic-leftover-2`, `mic-leftover-3` … per kind,
    /// in file order.
    static func audioSources(in folder: URL) -> [TranscriptFrontmatter.Source] {
        var counts: [Kind: Int] = [:]
        return find(in: folder).filter(\.kind.isAudio).map { file in
            let n = counts[file.kind, default: 0] + 1
            counts[file.kind] = n
            let id = n == 1 ? file.kind.rawValue : "\(file.kind.rawValue)-\(n)"
            return TranscriptFrontmatter.Source(id: id, resource: file.url.lastPathComponent)
        }
    }

    /// `<stem>.<label>.<ext>` gives (stem, 0); `<stem>.<label> N.<ext>` gives (stem, N).
    private static func labeled(_ name: String, label: String, ext: String) -> (stem: String, number: Int)? {
        let suffix = "." + ext
        guard name.hasSuffix(suffix) else { return nil }
        let base = String(name.dropLast(suffix.count))
        let marker = "." + label
        if base.hasSuffix(marker) {
            let stem = String(base.dropLast(marker.count))
            return stem.isEmpty ? nil : (stem, 0)
        }
        guard let range = base.range(of: marker + " ", options: .backwards) else { return nil }
        let digits = base[range.upperBound...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let number = Int(digits) else { return nil }
        let stem = String(base[..<range.lowerBound])
        return stem.isEmpty ? nil : (stem, number)
    }
}
```

- [ ] **Step 4: List extra audio in `sources`**

In `Roger/Services/MeetingRecording/MeetingTranscriptWriter.swift`, in `buildContent`, directly after the `if metadata.audioKept { ... }` block that appends `mic` and `system`:

```swift
        // Leftover and previous archives stay on disk whatever `audioKept`
        // says; list them so agents see all the audio.
        sources += MeetingExtraFiles.audioSources(in: session.folder)
```

- [ ] **Step 5: Add the error and the decision**

In `Roger/Models/MeetingRecordingError.swift`:

1. Add a case below `case trackAudioFailed(mic: Bool, system: Bool)`:

```swift
    /// The transcript was written, but some audio could not be merged into
    /// the archive. It is kept in these leftover files; there is nothing to retry.
    case audioSetAside(files: [String])
```

2. Add to `errorDescription`'s switch:

```swift
        case .audioSetAside(let files):
            return "Some audio could not be merged. It is saved as \(Self.listed(files)) in the meeting folder."
```

3. Add below `errorDescription`:

```swift
    /// The error a finished finalisation reports, or nil. Kept chunks mean a
    /// retry can help ("Try again"). Audio that only sits in a leftover file
    /// needs no retry, so the message says where it is instead.
    static func afterFinalisation(micNeedsRetry: Bool, systemNeedsRetry: Bool, setAside: [String]) -> MeetingRecordingError? {
        if micNeedsRetry || systemNeedsRetry {
            return .trackAudioFailed(mic: micNeedsRetry, system: systemNeedsRetry)
        }
        if !setAside.isEmpty {
            return .audioSetAside(files: setAside)
        }
        return nil
    }

    /// "a", "a and b", "a, b and c".
    static func listed(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
```

- [ ] **Step 6: Report leftovers from finalisation**

In `Roger/Services/MeetingRecording/MeetingRecordingService.swift`:

1. Replace

```swift
        var micLeftoverKept = false
        var systemLeftoverKept = false
```

with

```swift
        var micLeftover: URL?
        var systemLeftover: URL?
```

2. Replace `micLeftoverKept = encoded.leftoverKept` with `micLeftover = encoded.leftover`, and `systemLeftoverKept = encoded.leftoverKept` with `systemLeftover = encoded.leftover`.

3. Replace

```swift
        let micAudioFailed = (micOutcome?.needsRetry ?? false) || micLeftoverKept
        let systemAudioFailed = (systemOutcome?.needsRetry ?? false) || systemLeftoverKept
```

with

```swift
        let micAudioFailed = (micOutcome?.needsRetry ?? false) || micLeftover != nil
        let systemAudioFailed = (systemOutcome?.needsRetry ?? false) || systemLeftover != nil
```

4. Replace

```swift
        if micAudioFailed || systemAudioFailed {
            // The transcript lacks a track; its chunks were kept and the
            // session shows up again for a retry.
            state = .error(.trackAudioFailed(mic: micAudioFailed, system: systemAudioFailed))
        } else if sleepInterrupted {
```

with

```swift
        if let error = MeetingRecordingError.afterFinalisation(
            micNeedsRetry: micOutcome?.needsRetry ?? false,
            systemNeedsRetry: systemOutcome?.needsRetry ?? false,
            setAside: [micLeftover, systemLeftover].compactMap { $0?.lastPathComponent }
        ) {
            // Kept chunks: the session shows up again for a retry. A
            // leftover file only: the audio is safe there, nothing to retry.
            state = .error(error)
        } else if sleepInterrupted {
```

5. In `encodeTrack(_:into:)`, change the return type to `(result: AudioSegmentConcatenator.Result, landed: Bool, leftover: URL?)` and the three returns to:

```swift
            return (result, fm.fileExists(atPath: archive.path), nil)
```

```swift
        guard result.wrote, fm.fileExists(atPath: side.path) else { return (result, false, nil) }
```

```swift
        return (result, true, keepEncoded ? nil : side)
```

and replace the last sentence of its doc comment ("`leftoverKept` is true when …") with: "`leftover` is the side file when the new encode stays beside the archive, so the archive (and the transcript) does not have all of the audio."

Run `grep -n "leftoverKept" Roger/Services/MeetingRecording/MeetingRecordingService.swift`: it must print nothing.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`, including 8 new tests.

- [ ] **Step 8: Show extra files in the meeting detail**

`Roger/UI/Library/LibraryExtraFilesSection.swift`:

```swift
import AppKit
import SwiftUI

/// "Extra files" of a meeting: each with Reveal in Finder and Move to
/// Trash, plus Clean Up, which moves all of them to the Trash after a
/// confirmation. Never a permanent delete. Clean Up is offered only when
/// the meeting is not waiting for a retry. transcript.md is not changed.
struct LibraryExtraFilesSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    let item: LibraryItem
    @State private var files: [MeetingExtraFiles.File] = []
    @State private var confirmsCleanUp = false
    @State private var errorText: String?

    private var isLocked: Bool {
        !LibraryDocumentEditor.canEdit(item, activeSessionFolder: coordinator.meetingRecorder.activeSessionFolder)
    }

    var body: some View {
        Group {
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Extra files")
                            .font(.headline)
                        Spacer()
                        if !item.isUnfinished {
                            Button("Clean Up…") { confirmsCleanUp = true }
                                .disabled(isLocked)
                        }
                    }
                    Text("A retry left these files in the meeting folder. Leftover audio can hold parts of the meeting that are not in the transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(files, id: \.url) { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.kind.isAudio ? "waveform" : "doc.text")
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
                            Button {
                                trash([file.url])
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Move to Trash")
                            .disabled(isLocked)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .task(id: item) { refresh() }
        .confirmationDialog(
            files.count == 1 ? "Move 1 extra file to the Trash?" : "Move \(files.count) extra files to the Trash?",
            isPresented: $confirmsCleanUp,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trash(files.map(\.url)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can put them back from the Trash.")
        }
        .alert("Roger could not do that", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func refresh() {
        files = item.kind == .meeting ? MeetingExtraFiles.find(in: item.folderURL) : []
    }

    private func trash(_ urls: [URL]) {
        let failed = LibraryActions.moveToTrash(urls)
        refresh()
        if !failed.isEmpty {
            errorText = "Some files could not be moved to the Trash: \(failed.map(\.lastPathComponent).joined(separator: ", "))."
        }
    }
}
```

In `Roger/UI/Library/LibraryDetailView.swift`, in `LibraryItemDetail.preview`, insert at the top of the `VStack(alignment: .leading, spacing: 16)` inside the `ScrollView`, before `LibraryMarkdownView(`:

```swift
                    if item.kind == .meeting {
                        LibraryExtraFilesSection(item: item)
                    }
```

- [ ] **Step 9: Build, test and check by hand**

```bash
cd /Users/jordi/git/roger/Roger && xcodegen generate
git -C /Users/jordi/git/roger checkout -- Roger/Resources/Roger.entitlements
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build 2>&1 | grep -E "warning:|error:|BUILD" | tail -20
xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`. Then in the Debug app, copy a finished meeting folder to a scratch place inside the library, add empty files `mic.leftover.m4a` and `transcript.previous.md` with Finder or `touch`, and check: the detail shows "Extra files" with both; Reveal works; Clean Up… asks, then both files are in the Trash and the section disappears.

- [ ] **Step 10: Commit**

```bash
git -C /Users/jordi/git/roger diff --stat Roger/Resources/Roger.entitlements   # must print nothing
cd /Users/jordi/git/roger && git add Roger/Services/MeetingRecording Roger/Models/MeetingRecordingError.swift Roger/UI/Library Roger/RogerTests/MeetingExtraFilesTests.swift Roger/RogerTests/MeetingRecordingErrorTests.swift Roger/Roger.xcodeproj
git commit -m "feat: list and clean up extra files after a meeting retry"
```

---

### Task 12: Docs and full check

**Files:**
- Modify: `README.md` ("Recording meetings" folder path, new "Library" section)
- Modify: `AGENTS.md` (gitignored: edit, do not commit)

**Interfaces:**
- Consumes: everything above. Produces no code.

- [ ] **Step 1: README**

In `README.md`, section "### Recording meetings", replace

```
The result lands in a per-meeting folder under `~/Documents/Roger Recordings/` (configurable) with `mic.m4a`, `system.m4a` and `transcript.md`.
```

with

```
The result lands in a per-meeting folder under `~/Documents/Roger/Meetings/`, sorted by year and month, with `mic.m4a`, `system.m4a` and `transcript.md`.
```

In the next paragraph, after the sentence that ends "weaves the screenshots into `transcript.md` as inline images, so the folder reads as a chronological dataset of what was said and shown - hand it to an AI agent and it can follow the meeting slide by slide.", add:

```
If you finalise a meeting again, Roger keeps your edited segments and the old transcript as `.previous.md` files and lists any leftover audio in the transcript.
```

Add a new section after "### Recording meetings" and before "### Transcript format":

```markdown
### Library

Log entries, meetings and file transcripts all live in one folder, `~/Documents/Roger/` by default, sorted into `Logs`, `Meetings` and `Transcripts` by year and month. Open the library window from the menu bar, or set your own shortcut under Settings › General. Search everything Roger wrote, filter by kind and date, and sort by date, title or duration. Read an entry in place, fix a typo, give it a better title, drag it into a terminal or an agent, copy its path or move it to the Trash. File names never change, so paths you hand to an agent stay valid. While the window is open, Roger shows up in the Dock and in Cmd-Tab.
```

Check the new text: `grep -n "—\|–" README.md` may list older lines, but none of the lines you added.

- [ ] **Step 2: AGENTS.md (do not commit)**

In `AGENTS.md`:
- "Key Services": add
  - "**LibraryIndex / InMemoryLibraryIndex** - Actor that lists logs, meetings and transcripts from the library root, extra scan folders and the external-transcripts list. Built on first use, kept current by `LibraryFolderWatcher` (FSEvents, 0.5 s). `LibraryFrontmatterParser` and `LibraryItemReader` turn files into `LibraryItem`s; paths are compared through `LibraryPath.canonical` (realpath)."
  - "**LibraryDocumentEditor / LibraryActions** - Rename (title and H1 only), body save with a modification-date check, Trash plans that never take more than the selected entry."
  - "**MeetingExtraFiles** - Leftover and previous files a retry leaves; listed in `sources` and in the library. `MeetingArchiveMerge.moveAside` is the one move-aside helper (transcript, segments, archives)."
- "UI Layer": add "**LibraryWindowController** - NSWindow + NSHostingController for `LibraryView` (sidebar, day-grouped list, detail). Activation policy `.regular` while open, `.accessory` on close. Opened from the popover, the `openLibrary` shortcut or the last-entry card."
- "SettingsView" line: mention the Library shortcut in General and that Recordings no longer lists past recordings.
- Use hyphens, not em-dashes, in new text.

- [ ] **Step 3: Full test run**

```bash
cd /Users/jordi/git/roger/Roger && xcodebuild test -project Roger.xcodeproj -scheme Roger -destination 'platform=macOS' 2>&1 | tail -10
cd /Users/jordi/git/roger && git status --short   # AGENTS.md must not show up (gitignored)
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/jordi/git/roger && git add README.md
git commit -m "docs: describe the library window"
```

---

## Manual verification (after all tasks)

1. Popover > Open Library: window opens with a Dock icon, Cmd-Tab entry and Roger's menus. Cmd-, opens Settings. Close it: the Dock icon goes away. Reopen: same frame. Settings and onboarding alone never show a Dock icon.
2. Record a log entry with the Log preset while the library is open: it appears within about a second, under "Today". Click "Saved to log - Show in Library" in the popover: the entry is selected.
3. Search "two words": only entries with both words; matches highlighted in the preview. Date filter and all four sorts work; title sort shows a flat list.
4. Rename a meeting: `transcript.md` keeps its name, `title:` and the H1 change, every other line is the same (`git diff --no-index` against a copy).
5. Edit a log, change the file in another editor before Cmd-S: the conflict alert appears. "Discard my changes" reloads; "Overwrite" saves.
6. Drag one entry into Terminal and into Claude Code. Copy Path with several entries. Copy Folder Path on a log gives the month folder.
7. Move a log with audio to the Trash (both files go, no question). Move a meeting (asks, whole folder goes). Try to trash the meeting that is recording: refused.
8. Change the library folder in Settings > Recordings while the window is open: the list switches to the new folder.
9. Retry a meeting with screenshot segments you edited: your edits are in `<name>.previous.md`; the meeting detail lists them under "Extra files"; Clean Up moves them to the Trash.
10. Unfinished: with a pending session, the sidebar shows "Unfinished"; Finalise runs the retry; Dismiss hides it (also from the popover).
