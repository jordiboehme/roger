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
fake crlf 'Ingested 3 entries.\r\nRESULT: ok\r\n\r\n'
# A claude that says "RESULT: ok more" first and "RESULT: ok" on the second run.
cat > "$work/twice" <<SCRIPT
#!/bin/sh
if [ -e "$work/twice-ran" ]; then echo "RESULT: ok"; else touch "$work/twice-ran"; echo "RESULT: ok more"; fi
SCRIPT
chmod +x "$work/twice"
# A claude that always says "RESULT: ok more".
fake more 'RESULT: ok more\n'
# A claude that writes its arguments, one per line, to $work/args.
cat > "$work/args" <<SCRIPT
#!/bin/sh
printf '%s\n' "\$@" > "$work/args.txt"
echo "RESULT: ok"
SCRIPT
chmod +x "$work/args"

# allowed <expected> <description> [EXTRA_MCP_SERVERS]: checks the --allowedTools value.
allowed() {
  local expected=$1 description=$2
  rm -f "$work/args.txt"
  CLAUDE_BIN="$work/args" EXTRA_MCP_SERVERS="${3:-}" bash "$script" notes 1 > /dev/null 2>&1
  local got
  got=$(awk 'prev == "--allowedTools" { print; exit } { prev = $0 }' "$work/args.txt" 2>/dev/null)
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $description (got \"$got\", expected \"$expected\")"
    failures=$((failures + 1))
  else
    echo "ok: $description"
  fi
}

CLAUDE_BIN="$work/done" check 0 "RESULT: ok on the last line ends the loop" notes 3
CLAUDE_BIN="$work/spaces" check 0 "trailing spaces after RESULT: ok are fine" notes 3
CLAUDE_BIN="$work/quoted" check 1 "a RESULT line that is not the last line does not count" notes 3
CLAUDE_BIN="$work/failed" check 1 "RESULT: failed fails" notes 3
CLAUDE_BIN="$work/crlf" check 0 "CRLF output with RESULT: ok last is fine" notes 3
CLAUDE_BIN="$work/twice" check 0 "RESULT: ok more goes on to a second run that ends with ok" notes 3
CLAUDE_BIN="$work/more" check 0 "RESULT: ok more until max-runs ran out exits 0" notes 2
CLAUDE_BIN="$work/done" check 2 "max-runs 0 is refused" notes 0
CLAUDE_BIN="$work/done" check 2 "max-runs abc is refused" notes abc
CLAUDE_BIN="$work/done" check 2 "max-runs -1 is refused" notes -1
CLAUDE_BIN="$work/done" check 2 "max-runs 3x is refused" notes 3x
CLAUDE_BIN="$work/done" check 2 "a missing domain is refused"

allowed "mcp__roger" "only the Roger tools are allowed by default"
allowed "mcp__roger,mcp__crystalline" "EXTRA_MCP_SERVERS adds a server" "crystalline"
allowed "mcp__roger,mcp__a,mcp__b" "EXTRA_MCP_SERVERS takes commas and spaces" "a, b"

[ "$failures" -eq 0 ]
