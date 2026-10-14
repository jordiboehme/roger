# Roger MCP Server - Design

Date: 2026-10-13
Status: approved in brainstorming, awaiting spec review (updated 2026-10-14: skill install, Claude Desktop)
Target release: 0.25.0
Issue: #7

## Goal

A local agent (Claude Code or any MCP client) connects to Roger and picks up new log entries, meeting transcripts and file transcripts. It sees exactly what is new since its last visit, ingests it (for example into Crystalline) and confirms. Nothing is read twice and nothing is missed. Roger does not have to run for this.

The design follows the proven model of Notedown's MCP server (append-only change log, named consumer bookmarks, ack). Notedown is Rust (rmcp). Roger is Swift and uses the official Swift MCP SDK. Only the ideas carry over.

## Decisions from brainstorming

| Topic | Decision |
|---|---|
| Server process | Standalone stdio helper `roger-mcp` inside Roger.app, started by the client. Works while Roger is not running |
| Item content | Markdown (frontmatter and text) plus absolute paths of the item's files. Inputs never take paths, only keys |
| Change events | `created`, `updated`, `deleted`, written by Roger only. External file changes are not tracked. On `updated` the agent re-reads the whole item |
| Log storage | `.roger/changes.jsonl` and `.roger/consumers/<name>.json` inside the library folder |
| Scope of 0.25.0 | Server, Agents settings tab, ingest skill, unattended script, Homebrew symlink, skill install/update/uninstall in detected harnesses, Claude Desktop extension and skill |
| Platform | Local stdio only, macOS 15+ on Apple Silicon only. No HTTP, no OAuth, no Windows/Linux/x86_64 variants |
| Harness detection | Auto-detected by home folder, one row per detected harness |
| MCP registration | Through the harness's own CLI only. Otherwise a copyable command or snippet. Roger never writes another app's config file |
| Claude Desktop | Roger builds the `.mcpb` at runtime (binary server, absolute path of the running bundle's `roger-mcp`) and a skill zip for upload |

Out of scope: HTTP transport, OAuth, live actions (start recording, notifications), MCP resources and subscriptions, word-level diffs, tracking external file edits, log compaction.

## 1. Change log

### Files

```
<library root>/.roger/
├── changes.jsonl          append-only, one event per line
└── consumers/
    └── <name>.json        {"seq": 42, "updatedAt": "2026-10-13T18:02:11+02:00"}
```

### Event

```json
{"seq":42,"at":"2026-10-13T14:32:41+02:00","event":"created","kind":"log","key":"Logs/2026/10/2026-10-13 14-32-05","path":"Logs/2026/10/2026-10-13 14-32-05.md"}
```

| Field | Meaning |
|---|---|
| `seq` | Monotonic integer, starts at 1 |
| `at` | RFC 3339 time with local offset |
| `event` | `created`, `updated` or `deleted` |
| `kind` | `log`, `meeting` or `transcript` |
| `key` | Stable item id. Library-relative path without `.md`. For a meeting, the session folder (`Meetings/2026/10/2026-10-13 09-00`). For a transcript outside the library, `External/<file name>-<first 8 hex of SHA-256 of the absolute path>` |
| `path` | Main Markdown file. Library-relative inside the library, absolute for external transcripts |

When events are written:

| Event | Trigger |
|---|---|
| `created` | `LogEntryWriter` wrote an entry. A meeting got its first `transcript.md`. `TranscriptOutputWriter` wrote a transcript (library or next to the source) |
| `updated` | An edit or rename in the library window. A meeting retry rewrote `transcript.md` |
| `deleted` | An item was moved to the Trash from the library window |

### Writer

- `ChangeLog` (actor, in RogerKit) appends one line per event with a single `write` on a file opened with `O_APPEND`, under an exclusive `flock` held for read-last-seq plus append.
- `seq` = last valid `seq` in the file + 1. Readers skip a last line that does not parse (a write in progress or a crash).
- Writers call `append` only after their file is safely on disk. A failed append is logged as a warning. The item is caught up on the next start.

### First fill and catch-up

- At app start, `ChangeLog.reconcile(layout:extraFolders:externalFiles:)` lists all current items (library tree, extra scan folders, external transcript registry).
- Every item key that has never appeared in the log gets a `created` event. On a library without `changes.jsonl` that is every item, in recording-date order. A new consumer therefore starts with a full import.
- Keys whose last event is `deleted` are not re-added unless the file exists again.
- The same runs when the library root changes to another folder.
- Reconcile does not detect edits or deletions done outside Roger (out of scope).

### Size

About 250 bytes per event. No compaction.

## 2. Tools

All output is text. Lists are TOON. Documents are Markdown. The server instructions explain TOON and the ingest loop in a few lines.

| Tool | Input | Output | Annotations |
|---|---|---|---|
| `status` | none | Library path, item counts per kind, last `seq`, consumers with bookmark `seq`, age and number of open events | readOnly |
| `get_changes` | exactly one start: `consumer` or `since` or `from` + `upTo`. Optional `kinds` (array of `log`, `meeting`, `transcript`), `summary` (bool, default false) | Head (`from`, `upTo`, `more`, `count`) then one entry per item | readOnly |
| `ack` | `consumer`, `upTo` (int) | Short confirmation with the new and previous `seq` | not readOnly, idempotent |
| `get_item` | `key` | Markdown of the item, then a `paths` block | readOnly |
| `list_items` | `kind?`, `since?`, `limit?` (default 50, max 500) | TOON: key, kind, title, date, duration, paths | readOnly |
| `search` | `query`, `kind?`, `limit?` (default 20, max 100) | TOON: key, kind, title, date, snippet | readOnly |

### get_changes

- Start rules:
  - `consumer`: start after that consumer's bookmark. Unknown consumer = bookmark 0.
  - `since`: a `seq` (integer), a date (`YYYY-MM-DD`), an RFC 3339 time or a duration (`30m`, `12h`, `3d`). Time forms select events with `at` at or after that time.
  - `from` + `upTo`: the fixed inclusive range, for sub-agents that must see the same state as a summary.
  - Zero or more than one start form: `isError` with a message that names the rule.
- Within the selected range, events are grouped by `key` and only the latest event per key is returned, at that event's `seq` position.
- Entry fields: `seq`, `event`, `kind`, `key`, `title`, `date`, `duration`, `paths` (absolute paths of the `.md`, an `.m4a` if present, `mic.m4a`/`system.m4a` and screenshots for meetings), then the full Markdown unless `summary` is true. A `deleted` entry has no text and no paths.
- If the item file is missing for a `created` or `updated` event, the entry says `missing: true` with no text.
- Size: entries are added until the text reaches about 30,000 characters, then cut at the item boundary. `upTo` is the last included `seq` and `more` tells whether events remain. A single entry larger than the limit is still returned whole. With `summary: true` the limit is 45,000 characters, below the 50,000 characters Claude Code shows inline. `get_changes` and `get_item` also declare `_meta["anthropic/maxResultSizeChars"]: 500000`, so a single large entry still arrives inline.
- Tool description spells out the loop: `get_changes(consumer)`, ingest, `ack(consumer, upTo)`, repeat while `more`. With `since`, the next call passes the previous `upTo` as `since`.

### ack

- Sets the bookmark to `upTo` if it is higher. Never moves it backwards (an older `upTo` returns the current bookmark unchanged, no error).
- `upTo` greater than the last `seq` in the log is an error.
- Writes `consumers/<name>.json` atomically (temp file plus rename).

### Validation

- Consumer names: `^[a-z0-9][a-z0-9-]{0,63}$`.
- Keys are resolved against the library root and must stay inside it after standardization, or match an `External/` key from the log. Anything else (`..`, absolute paths) is `isError`.
- No tool takes a file path. No tool deletes anything.

### Search

Case-insensitive scan over title and body of all current items, every word must match, newest first. No index (same reasoning as the library window).

## 3. Helper and build

### Targets (XcodeGen)

- `RogerKit` (static library, no FluidAudio): `LibraryLayout`, `ChangeLog`, `ConsumerBookmarks`, `LibraryItem` lookup and frontmatter reading, `TOONEncoder`, `ChangeQuery` (the `get_changes` logic), `ItemSearch`. The app links it and keeps its writers.
- `RogerKitTests` (unit tests without a host app).
- `roger-mcp` (command-line tool, Swift 6, macOS 15): depends on `RogerKit` and `modelcontextprotocol/swift-sdk` (product `MCP`). Runs `Server` with `StdioTransport` until stdin closes.
- The Roger app target copies `roger-mcp` into `Roger.app/Contents/MacOS/roger-mcp` and signs it with hardened runtime and the same team. The release workflow verifies the nested binary's signature and notarization.

### Library lookup

1. `--library <path>`
2. `CFPreferencesCopyAppValue("libraryRoot", "com.jordiboehme.roger")`
3. `~/Documents/Roger/`

If the folder or `.roger/changes.jsonl` is missing, `status` reports "Start Roger once to set up the library" and the other tools return that as `isError`.

### Behavior

- stdout carries MCP only. Logs go to `os.Logger`, and to stderr with `--verbose`.
- Server name `roger`, version from the enclosing Roger.app Info.plist. `roger-mcp --version` prints it.
- Only writes: consumer bookmark files.
- macOS asks the parent app (Terminal, iTerm) for Documents access on first use. Expected, and documented in the Agents tab and the README.

### Homebrew

The cask generated in the release workflow gets `binary "#{appdir}/Roger.app/Contents/MacOS/roger-mcp"`.

## 4. Setup, skill and script

### Agents settings tab

- Status: library path, event count, time of the last event.
- Harness rows (see "Skill install"), then the Claude Desktop row.
- Manual setup (collapsed): command with copy button, `claude mcp add --scope user roger -- roger-mcp` when `roger-mcp` is on the PATH, else the bundle path; JSON snippet for `.mcp.json` and other clients.
- Consumers: name, bookmark age, open events. Actions "Start over" (bookmark to 0) and "Forget" (delete bookmark), each after a confirmation.
- One line about the Documents permission prompt.

### Skill install

Harness detection: a harness is detected when its home folder exists.

| Harness | Detected by | Skills folder | MCP CLI |
|---|---|---|---|
| Claude Code | `~/.claude` | `~/.claude/skills` | `claude mcp add --scope user roger -- <roger-mcp>` |
| Codex | `~/.codex` | `~/.agents/skills` | `codex mcp add roger -- <roger-mcp>` |
| Gemini CLI | `~/.gemini` | `~/.agents/skills` | `gemini mcp add --scope user roger <roger-mcp>` |
| Cursor | `~/.cursor` | `~/.agents/skills` (also reads `~/.claude/skills`) | none: JSON snippet for `~/.cursor/mcp.json` |
| Copilot CLI | `~/.copilot` | `~/.copilot/skills` | none: JSON snippet for `~/.copilot/mcp-config.json` |
| Kiro | `~/.kiro` | `~/.kiro/skills` | none: JSON snippet for `~/.kiro/settings/mcp.json` |

The exact CLI syntax and config paths are checked against current docs during planning; the table is the intent.

- Source: `skills/ingest-roger/SKILL.md` in the repo, bundled into Roger.app as a resource. Its version is the app version; its SHA-256 decides whether a file changed.
- Install: copy (never a link) into `<skills folder>/ingest-roger/SKILL.md` via temp file plus rename. A folder shared by several harnesses is written once; the other rows say "covered by <harness>". Then register the server with the harness CLI if one exists and is found (login shell PATH plus `/opt/homebrew/bin`, `/usr/local/bin`). A missing CLI or a failing command is not an error: the row shows the exact command or snippet with Copy.
- Roger never writes another app's config file. It only reads them (and runs `<cli> mcp list` where available) to show "server connected" or "not connected".
- Receipt: `~/Library/Application Support/Roger/skill-installs.json`, per skills folder: version and SHA-256. It is treated as untrusted: Roger only ever touches `ingest-roger` inside the known skills folders.
- Row states: not installed, up to date, outdated (receipt version older than the app), changed by you (file hash differs from the receipt), plus server connected / not connected.
- Checked when the Agents tab opens. After an app update with outdated installs, the menu bar popover shows one quiet hint ("Agent skill outdated - update in Settings"). Never updates on its own.
- Update: a file changed by the user is saved as `SKILL.md.bak` first; the row says so.
- Uninstall: removes the skill folder only when the file is unchanged; a changed file asks first and then goes to the Trash. Then `<cli> mcp remove roger` where a CLI exists, else the row shows the command.

### Claude Desktop

Shown when `/Applications/Claude.app` exists.

- "Add to Claude Desktop": Roger writes `roger.mcpb` to a temp folder (manifest with server type `binary`, `mcp_config.command` = absolute path of the running bundle's `roger-mcp`, name `roger`, version = app version, icon) and opens it with Claude Desktop, which shows its install dialog. Same name means an update. No Node shim and no release asset.
- "Save skill for Claude Desktop": writes `ingest-roger.zip` (`ingest-roger/SKILL.md`) to `~/Downloads` and reveals it, with the hint "Upload in Claude > Settings > Capabilities > Skills".
- Roger cannot read Desktop's state. The row shows when each step was last done and warns "Roger.app moved - add again" when the stored path no longer matches the running bundle.
- The `.mcpb` manifest format is checked against the current MCPB spec during planning.

### Ingest skill (`skills/ingest-roger/SKILL.md`)

- Consumer `crystalline`. Loop: `get_changes(consumer, summary: true)`, plan groups, `get_changes(from, upTo, kinds)` per group, ingest, `ack(consumer, upTo)` only after the whole range succeeded. Repeat while `more`.
- Mapping: log entries become observations (decisions, tasks, facts, ideas), entries of one day on one topic share an engram. A meeting becomes one engram (participants, decisions, action items, open questions), screenshots read through their paths. A file transcript becomes one source summary.
- Idempotency: every engram stores `roger://<key>` in `sources`. Before writing, search with `$contains_any`. `updated` updates the engram, `deleted` sets it to `archived`.
- Target domain from the argument (`/ingest-roger <domain>`), or asked. Never guessed.
- Follows the Crystalline rules: search before writing, reuse tags.
- Ends with `RESULT: ok` or `RESULT: failed: <reason>`.

### Script (`scripts/ingest-roger.sh`)

- Runs `claude -p "/ingest-roger <domain>"` with an allowlist of only the `roger` and `crystalline` MCP tools, in a loop while the skill reports more work.
- Continues only on `RESULT: ok`. Exits 1 on failure, so the next run repeats the range.
- README has an example launchd plist. The script installs nothing.

## 5. Testing

Unit tests in `RogerKitTests`:

- ChangeLog: increasing `seq`; two handles appending under `flock` give no duplicate `seq`; a half-written last line is skipped; first fill from a fixture library in recording-date order with correct keys; reconcile adds missing items once and does not re-add deleted keys.
- Bookmarks: never backwards, name validation, unknown consumer starts at 0, atomic write.
- ChangeQuery: start rule errors; one entry per key; `deleted` without text; `missing: true`; 30,000-character cut at an item boundary with `more`; a single oversized entry returned whole; `kinds`; `summary`; `since` in all four forms.
- TOONEncoder: quoting and escapes against fixed samples.
- Tools: each handler called directly with JSON arguments, including errors and rejected keys (`..`, absolute paths).
- End to end: start the built `roger-mcp --library <temp>` as a process, send `initialize`, `tools/list` and `get_changes` over stdin, check the responses and that stdout holds only JSON-RPC.

- Skill install (app tests on temp folders): detection, install plan with shared folders, receipt states (outdated, changed by you), `.bak` on update, uninstall refuses a changed file without confirmation, receipt entries outside known folders ignored, CLI calls through a fake runner (success, missing CLI, failure).
- `.mcpb` builder: manifest content and zip layout; skill zip layout.

Manual: Install in Claude Code from the Agents tab and a real `/ingest-roger` run; Add to Claude Desktop; the script once by hand; the Agents tab including "Start over".

## 6. Delivery

One plan, in this order:

1. Extract `RogerKit` and add `RogerKitTests`.
2. `ChangeLog` in the app: writer, first fill, catch-up. Wire `LogEntryWriter`, meeting finalisation (including retries) and `TranscriptOutputWriter`.
3. `roger-mcp` with the six tools, bundling, signing and the cask stanza.
4. Agents settings tab with status and consumers.
5. Skill, script and README.
6. Skill install/update/uninstall with harness detection and CLI registration.
7. Claude Desktop: `.mcpb` builder and skill zip.

Dependency on the library window (#6): shipped in 0.24.0. This plan wires its edit, rename and trash actions (`LibraryDocumentEditor`, `LibraryActions.moveToTrash`) to `ChangeLog` as the source of `updated` and `deleted`.
