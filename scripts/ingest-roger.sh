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
  result=$(printf '%s\n' "$output" | awk '{ sub(/\r$/, "") } NF { last = $0 } END { sub(/[ \t\r]+$/, "", last); print last }')
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
