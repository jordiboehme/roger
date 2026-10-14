#!/usr/bin/env bash
# Builds Roger (Debug) and renders every settings pane into PNG files:
# settings-<pane>.png (light), settings-<pane>-dark.png and
# settings-<pane>-min.png (minimum window size). Roger quits on its own.
# The run changes no setting except the one-time duration migration.
#
# Usage: scripts/settings-snapshots.sh <folder>
# The folder must not exist yet, or be empty.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <folder>" >&2
  exit 1
fi
out=$1
if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
  echo "error: $out is not empty" >&2
  exit 1
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo/Roger"
xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug build -quiet
products=$(xcodebuild -project Roger.xcodeproj -scheme Roger -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / { print $2; exit }')

"$products/Roger.app/Contents/MacOS/Roger" -RogerSnapshotDir "$out" -RogerSnapshotSettings YES

count=$(find "$out" -name 'settings-*.png' | wc -l | tr -d ' ')
echo "$count images in $out"
if [ "$count" -ne 30 ]; then
  echo "error: expected 30 images" >&2
  exit 1
fi
