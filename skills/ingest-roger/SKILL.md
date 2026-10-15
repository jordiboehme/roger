---
name: ingest-roger
description: Read and ingest Roger log entries, meeting transcripts and file transcripts. Use when the user asks to ingest, import, sync or read Roger, or runs /ingest-roger.
---

# Ingest Roger

Roger is a speech-to-text app on this Mac. Its MCP server `roger` serves log entries, meeting transcripts and file transcripts from Roger's library. This skill teaches you how to read them correctly: what is new, what changed and how to confirm what you processed, so nothing is read twice and nothing is missed.

This skill is about getting the data. What you do with it is up to you and the user's knowledge system. Process each item with your knowledge system's own ingestion method. With Crystalline, use the "Ingesting a source" section of the `crystalline-capture` skill.

Your client may show the tools with a prefix (for example `mcp__roger__get_changes`). Use whatever name it gives them.

## Arguments

`/ingest-roger [consumer]`. The consumer names who reads the changes. Roger remembers for each consumer what it confirmed. The default is `crystalline`. Use one consumer per knowledge system, so two systems never take each other's changes.

## Before you start

Call `status`. If its `state` is not `ready`, stop with `RESULT: failed: <the message from status>`.

## The loop

1. Call `get_changes(consumer: <consumer>, summary: true)`. Note `from`, `upTo`, `more`, `library` and the entries (key, event, kind, title, date). A summary has no Markdown.
2. Fetch each kind once. For every kind in the summary, call `get_changes(from: <from>, upTo: <upTo>, kinds: [<kind>])` with `from` and `upTo` from step 1. If that answer has `more: true`, call again with `from` set to its `upTo + 1` and the same `upTo` until `more` is false. Do not fetch the range again for each item.
3. Process every entry of the range (see "What an entry is").
4. Only when the whole range was processed, call `ack(consumer: <consumer>, upTo: <upTo from step 1>, library: <library from step 1>)`. Never ack the `upTo` of a call with `kinds`. If anything failed, do not ack: end with `RESULT: failed: <reason>`, so the next run repeats the range. If `ack` refuses because the library changed, Roger now uses another library: start again at step 1 (this counts as a round).
5. If `more` in step 1 was true, start again at step 1. Do at most 5 rounds in one run.

## What an entry is

- Each entry is one item in its latest state. It starts with the line `==== roger entry <seq> ====`, lists its fields (`seq`, `event`, `kind`, `key`, `title`, `date`, `duration`, `paths`) and has the item's Markdown after a blank line.
- Kinds: `log` (a short spoken note, sometimes with "Me" and "Other N" speakers when it also recorded the computer's sound), `meeting` (a transcript with speakers and optional screenshots) and `transcript` (a transcript of a media file).
- Events: `created`, `updated` and `deleted`. On `updated`, read the item again as a whole: the earlier version is gone. On `deleted`, what was made from the item may need to go. An entry with `missing: true` names an item whose file is gone; skip it and mention it in your summary.
- `roger://<key>` is the stable address of an item. Use it wherever your knowledge system records where something came from.
- `seq` grows with every change of an item, so it works as the version of what you read.
- Screenshots of meetings come as file paths in `paths`. Open them when they show something that matters. If a path cannot be read, go on without it.

## Frontmatter

The frontmatter is Roger's metadata about the Markdown file. Keys such as `type`, `status`, `tags` and `sources` describe the file in Roger's library, not how you should store the knowledge. Do not copy them over as they are. Decide yourself what they tell you, for example when something was said (`started_at`), how long it took or which speakers there were.

## Other tools

- `get_item(key: <key>)` reads one item by key.
- `list_items(kind, since, limit)` lists items, newest first. All three are optional.
- `search(query, kind, limit)` finds items by text.

Use them when the user asks about something outside the change feed, for example a meeting from last month. They do not change what the consumer confirmed.

## Result

End with exactly one of these lines as the last line:

- `RESULT: ok` when nothing is left (`more` was false),
- `RESULT: ok more` when you stopped after 5 rounds and `more` was still true,
- `RESULT: failed: <reason>` when something went wrong. Do not ack the range in that case.
