#!/usr/bin/env bash
# Fails when the app version, its generated pins or the release notes disagree.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
err() { echo "error: $*" >&2; fail=1; }

version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' Roger/project.yml | head -n1)
if [ -z "$version" ]; then
  echo "error: no MARKETING_VERSION found in Roger/project.yml" >&2
  exit 1
fi
echo "App version: $version"

pbx=Roger/Roger.xcodeproj/project.pbxproj
pins=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$pbx")
if [ -z "$pins" ]; then
  err "no MARKETING_VERSION in $pbx (run xcodegen generate)"
fi
for pin in $pins; do
  if [ "$pin" != "$version" ]; then
    err "$pbx has MARKETING_VERSION $pin, project.yml has $version (run xcodegen generate)"
  fi
done

notes="release-notes/v${version}.md"
if [ ! -s "$notes" ]; then
  err "$notes is missing or empty"
elif ! head -n1 "$notes" | grep -q '^# '; then
  err "$notes must start with a '# ' heading (the release motto)"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "Version pins: ok."
