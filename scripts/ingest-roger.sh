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
# was ingested, 1 when a run failed (the next run repeats the same range).
# Also exits 0 when max-runs ran out and there is still more: the next call goes on.
# Installs nothing.
set -euo pipefail

domain="${1:-}"
runs="${2:-10}"
if [ -z "$domain" ]; then
  echo "Usage: $0 <crystalline-domain> [max-runs]" >&2
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
  result=$(printf '%s\n' "$output" | grep -E '^RESULT: ' | tail -n 1 || true)
  case "$result" in
    "RESULT: ok")
      exit 0
      ;;
    "RESULT: ok more")
      continue
      ;;
    *)
      echo "ingest-roger: ${result:-no RESULT line} in run $run" >&2
      exit 1
      ;;
  esac
done

echo "ingest-roger: there is still more after $runs runs. Run it again later." >&2
exit 0
