# Text Input and Fixes (Roger 0.26.0, part A) Design

Roger 0.26.0 has two parts. Part A (this spec) makes every text read go through one place, fixes the open issues #10 to #15 and the findings set aside in 0.25.0. Part B, the settings overhaul, has its own spec.

## Goals

- Roger reads any text file the same way: UTF-8 text with LF line endings, whatever encoding or line endings the file has.
- No parser handles `\r` on its own.
- The open issues #10, #11, #12, #13, #14 and #15 are closed.
- The 0.25.0 findings listed in section 4 are fixed.

## Decisions

| Topic | Decision |
|---|---|
| Files on disk | Normalize on read only. Roger never rewrites a file just to convert it. When Roger writes a file anyway (edit, rename, retry), it writes UTF-8 with LF. |
| Encoding order | BOM first (UTF-8, UTF-16 LE/BE, UTF-32 LE/BE), then UTF-8, then Windows-1252. |
| Line endings | `\r\n` and a lone `\r` become `\n`. |
| JSON files | Keep `JSONDecoder` / `JSONSerialization` on raw `Data` (they accept `\r` as whitespace). |
| SKILL.md compare | Stays a byte compare (SHA-256). |
| Library switch during ingest (#15) | `get_changes` names the library, `ack` takes it back optionally and refuses a different one. |

## 1. TextFile

New file `Roger/RogerKit/TextFile.swift`, public, Foundation only.

```swift
public enum TextFile {
    /// Reads a text file as UTF-8 with LF line endings.
    public static func read(_ url: URL) throws -> String
    /// Decodes bytes: BOM, then UTF-8, then Windows-1252. Line endings become LF.
    public static func decode(_ data: Data) -> String
    /// \r\n and a lone \r become \n.
    public static func normalizeLineEndings(_ text: String) -> String
}
```

- `decode` never fails. Windows-1252 maps every byte (the five undefined bytes 0x81, 0x8D, 0x8F, 0x90, 0x9D map to the same code points as in Latin-1).
- A BOM is removed from the result.
- `read` throws only the file system error (missing file, no permission), never an encoding error.

### Users of TextFile

Every place that reads text and parses it switches to `TextFile`:

- `LibraryItemReader` (item text), `LibraryFrontmatterParser` callers.
- `LibraryDocument.load`, `rename`, `saveBody` (the mtime check stays).
- `MeetingSegmentWriter` (existing segment read, `sameContent`, `isDraft`).
- `MeetingSessionScanner.transcriptReportsFailedAudio`.
- `LibraryActions.hasMeetingTranscript`.
- `ItemResolver.markdown(of:)` (and through it `get_item` and search).
- `HarnessRegistration` TOML reader (Codex `config.toml`).
- `LibraryMarkdown` gets already normalized text from the document.

The `\r` special cases go away: the kept `\r` on the H1 line in `LibraryDocument` and any `\r` trimming in parsers. Quoted frontmatter values keep their `\r` escape (that is a value, not a line ending).

Writers already write UTF-8 with LF and stay as they are. The editor's body is normalized before it is saved.

### Tests

For each of CRLF, CR only, a UTF-8 BOM, UTF-16 LE with BOM and Windows-1252 with umlauts:

- `TextFile.decode` gives the expected UTF-8 text with LF.
- The frontmatter parser finds title, date and tags.
- The library reader gives the right item (title, first line, search text).
- Rename changes the frontmatter title and the H1, and the file is UTF-8 with LF afterwards.
- Save writes UTF-8 with LF and keeps the frontmatter.
- A retry compare of an unchanged CRLF segment counts as unchanged.
- The Codex TOML reader finds the roger command in a CRLF file.

## 2. Open issues

### #12 Library window

- Rename field: a click elsewhere commits the new name (like Finder). Esc cancels.
- After rename or save the header and the row update at once from the saved file, not after the folder watcher.
- After a save, the edited entry stays in the list and selected even when it no longer matches the search or filter, until another entry is selected.
- While Unfinished is selected, search, the date filter and sort are disabled.
- The Extra files section reloads when the index reports a change in that meeting folder.
- Clean Up shows a short message when it refuses because a retry started while the dialog was open.
- The list keeps its scroll position and focus when it goes from empty to filled. The row height problem the `.id(model.results.isEmpty)` rebuild worked around gets a fix that does not rebuild the list.
- A meeting folder with a subfolder shows the Extra files section. A subfolder is one row that can be revealed but not trashed.
- Title sort for logs uses the row text (the first line of the body), not the hidden "Log <date> <time>" title.

### #13 Library index

- Hidden `.md` files are ignored by incremental updates, as in the full scan.
- Meeting folders at any depth (including extra scan folders) get incremental updates.
- When the library root is missing, Roger does not watch a parent folder. The library window shows "Library folder not found". Roger checks again when the app becomes active and when the root setting changes.
- Unfinished meetings with only audio chunks count the chunks as audio.
- `scopeChangeStopsTheOldIndex` waits for a condition, not a fixed number of yields.

### #14 Meetings and library

- A mic-track retry error names the system leftover file too.
- "Relaunch Roger" asks about unsaved edits first, then relaunches. The quit prompt and the relaunch helper never run at the same time.
- Editing an entry whose `.md` is a symlink writes through the link to its target. The link stays.
- "Finalise" is offered only for real Roger session folders, with the same check Trash uses (`LibraryActions.isRogerSessionFolder`).

### #15 ack after a library switch

- `get_changes` puts `library: <canonical root path>` in its TOON head.
- `ack` takes an optional `library` argument. If it is given and differs from the current canonical root, `ack` refuses: "The library changed since get_changes. Call get_changes again." Nothing is written.
- Without `library`, `ack` behaves as before.
- The ingest-roger skill passes `library` from its summary call to `ack`.

### #10 Testability

- The decisions in `AppCoordinator` and `MeetingRecordingService` move into small types that tests drive with a temp folder and fake inputs:
  - saving a log entry after dictation (preset output, keep audio, sources),
  - the first-launch library migration,
  - the meeting finalisation steps (transcript write, segment write, leftover handling, change recording).
- Under tests, the app does not build the full `AppCoordinator`. The test host never reads the real library folder.
- Each extracted type gets tests for its main paths and its failure paths.

## 3. Behavior that stays

- File names never change on write.
- Library files are the user's data. Nothing in this part deletes or overwrites an item file beyond the existing rules.
- Change events are recorded only after a write succeeded.

## 4. Findings set aside in 0.25.0

1. `fsync` after each change log append, and on the bookmark temp file before the rename.
2. Cached date formatters and JSON decoder in the change log parse.
3. Agents tab: the `roger-mcp` path check, Start over and Forget run off the main actor. Consumers are listed even when `changes.jsonl` is missing.
4. `roger-mcp`: an unexpected error names the tool and the library. `status` reports a change log it cannot read instead of "ready, 0 events".
5. Codex TOML reader accepts a trailing `# comment` after the command and a quoted `[mcp_servers."roger"]` header.
6. `LibraryChangeRecorder.recordWritten` takes the root the writer used.
7. The library index and `LibraryScanner` use one rule for a file found twice.
8. `scripts/ingest-roger.sh` validates the run count (a positive integer, else exit 2) and reads `RESULT:` only from the last non-empty line of output.
9. `release.yml` checks that `roger-mcp` has the app's TeamIdentifier and a secure timestamp.
10. Small cleanups: the TOON key check rejects a trailing newline (no regex `$`), patterns compiled once, the session folder date formatter reused, the Claude Desktop extension icon at 512 px.
11. Missing tests: `ensureFile` leaves an existing log byte for byte, the six tools write nothing in an empty library, the `search` limit clamp, Trash with a failed `.md` and a working `.m4a`.

Left out on purpose: the symlink check race in the skill installer, pid reuse after a forced kill, a call that arrives right before `roger-mcp` exits, `since` with a clock that went backwards, Cursor seeing the skill twice, Install next to an unreadable config.

## Testing

- Swift Testing, as before. RogerKit parts in RogerKitTests, app parts in RogerTests.
- Tests never construct `AppState` or `AppCoordinator`, never touch `UserDefaults.standard`, `~/Documents` or real harness folders.
- CI runs both test targets and the bundle check.

## Delivery

1. TextFile and its users (#11).
2. #13 library index.
3. #12 library window.
4. #14 meetings and library.
5. #15 and the MCP findings (4, 1, 2).
6. #10 testability.
7. Remaining findings (3, 5 to 11).

The release notes for 0.26.0 are written once part B is done.
