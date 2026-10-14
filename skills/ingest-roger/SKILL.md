---
name: ingest-roger
description: Ingest new Roger log entries, meeting transcripts and file transcripts into Crystalline. Use when the user asks to ingest, import or sync Roger, or runs /ingest-roger <domain>.
---

# Ingest Roger

Roger is a speech-to-text app on this Mac. Its MCP server `roger` serves log entries, meeting transcripts and file transcripts. This skill brings new and changed items into Crystalline and then confirms them, so nothing is read twice and nothing is missed.

Your client may show the tools with a prefix (for example `mcp__roger__get_changes` or `mcp__crystalline__write_engram`). Use whatever name it gives them.

## Target domain

- The Crystalline domain is the first argument: `/ingest-roger <domain>`.
- Without an argument, ask the user which domain to use. Never guess a domain.
- When nobody can answer (an unattended run), stop with `RESULT: failed: no domain given`.

## Before you start

1. Call `roger` `status`. If the library is not ready, stop with `RESULT: failed: <the message from status>`.
2. Read the domain's conventions in Crystalline (its MANIFEST and `vocabulary`). Reuse its tags, folders and categories. Search before you write anything.

## The loop

The consumer name is always `crystalline`.

1. Call `get_changes(consumer: "crystalline", summary: true)`. Note `from`, `upTo`, `more` and the entries (key, event, kind, title, date).
2. Plan groups:
   - log entries of the same day and the same topic go together,
   - every meeting is its own group,
   - every file transcript is its own group.
3. Fetch each kind once. For every kind in the summary, call `get_changes(from: <from>, upTo: <upTo>, kinds: [<kind>])` with `from` and `upTo` from step 1. If that answer has `more: true`, call again with `from` set to its `upTo + 1` and the same `upTo` until `more` is false. Keep these entries and take every group of that kind from them. Do not fetch the range again for each group. For meetings, open the screenshots through their paths when they show something that matters.
4. Ingest the group (see "What to write").
5. Only when every group of the range succeeded, call `ack(consumer: "crystalline", upTo: <upTo from step 1>)`. Never ack the `upTo` of a call with `kinds`.
6. If `more` in step 1 was true, start again at step 1. Do at most 5 rounds in one run.

## What to write

- **Log entries** become observations (`[decision]`, `[task]`, `[fact]`, `[idea]`). Entries of one day on one topic share one engram. Keep the speaker's words where they matter. Name people, dates and amounts.
- **A meeting** becomes one engram: who spoke (the speaker labels as they are), what was decided, action items with owner and due date when said, open questions and a short summary. Mention what the screenshots show where it helps.
- **A file transcript** becomes one source summary engram: what the recording is, the main points and anything worth keeping.

## Never twice

- Every engram you write lists `roger://<key>` in `sources` for each Roger item it covers.
- Before you write, search with `metadata_filters: {"sources": {"$contains_any": ["roger://<key>", ...]}}`. If an engram already covers the item, edit it instead of writing a new one.
- `updated`: read the whole item again and update the engram.
- `deleted`: when the engram covers only deleted items, set its status to `archived`. Otherwise remove that item's observations and its `roger://<key>` source.
- `missing: true`: skip the entry and mention it in your summary.

## Result

End with exactly one of these lines as the last line:

- `RESULT: ok` when nothing is left (`more` was false),
- `RESULT: ok more` when you stopped after 5 rounds and `more` was still true,
- `RESULT: failed: <reason>` when something went wrong. Do not ack the range in that case, so the next run repeats it.
