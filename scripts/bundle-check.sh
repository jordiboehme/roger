#!/usr/bin/env bash
# Checks a built Roger.app before it ships: Info.plist keys, executables,
# architectures, the bundled skill and the code signature.
# Usage: scripts/bundle-check.sh path/to/Roger.app
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 path/to/Roger.app" >&2
  exit 2
fi

app=${1%/}
root="$(cd "$(dirname "$0")/.." && pwd)"

fail=0
err() { echo "error: $*" >&2; fail=1; }

if [ ! -d "$app" ]; then
  echo "error: $app is not a folder" >&2
  exit 1
fi

plist="$app/Contents/Info.plist"
if [ ! -f "$plist" ]; then
  echo "error: $plist is missing" >&2
  exit 1
fi

# Prints the raw value of a key, or nothing when the key is missing.
key() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true; }

expect_key() {
  local name=$1 want=$2 got
  got=$(key "$name")
  if [ -z "$got" ]; then
    err "Info.plist has no $name (want $want)"
  elif [ "$got" != "$want" ]; then
    err "Info.plist has $name $got, want $want"
  fi
}

version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$root/Roger/project.yml" | head -n1)
if [ -z "$version" ]; then
  err "no MARKETING_VERSION found in Roger/project.yml"
fi

expect_key CFBundlePackageType APPL
expect_key CFBundleIdentifier com.jordiboehme.roger
if [ -n "$version" ]; then
  expect_key CFBundleShortVersionString "$version"
fi
expect_key LSMinimumSystemVersion 15.0
expect_key LSUIElement true

exe_name=$(key CFBundleExecutable)
main_exe=""
if [ -z "$exe_name" ]; then
  err "Info.plist has no CFBundleExecutable"
else
  main_exe="$app/Contents/MacOS/$exe_name"
  if [ ! -f "$main_exe" ]; then
    err "main executable Contents/MacOS/$exe_name is missing"
    main_exe=""
  elif [ ! -x "$main_exe" ]; then
    err "main executable Contents/MacOS/$exe_name is not executable"
  fi
fi

mcp="$app/Contents/MacOS/roger-mcp"
if [ ! -f "$mcp" ]; then
  err "Contents/MacOS/roger-mcp is missing"
  mcp=""
elif [ ! -x "$mcp" ]; then
  err "Contents/MacOS/roger-mcp is not executable"
fi

for bin in "$main_exe" "$mcp"; do
  [ -n "$bin" ] || continue
  archs=$(lipo -archs "$bin" 2>/dev/null || echo "unknown")
  if [ "$archs" != "arm64" ]; then
    err "${bin#"$app/"} has architectures '$archs', want 'arm64' only"
  fi
done

skill="$app/Contents/Resources/skills/ingest-roger/SKILL.md"
if [ ! -s "$skill" ]; then
  err "bundled skill Contents/Resources/skills/ingest-roger/SKILL.md is missing or empty"
fi

# The linker gives every arm64 binary an ad-hoc signature, so codesign -dv
# succeeds even on an unsigned build. Only a real signature seals resources.
if [ -f "$app/Contents/_CodeSignature/CodeResources" ]; then
  if ! codesign --verify --strict --verbose=2 "$app"; then
    err "code signature of the app is not valid"
  fi
  if [ -n "$mcp" ] && ! codesign --verify --strict --verbose=2 "$mcp"; then
    err "code signature of roger-mcp is not valid"
  fi
else
  echo "Roger.app is unsigned, signature not checked."
fi

if [ "$fail" -ne 0 ]; then
  echo "Bundle check: failed." >&2
  exit 1
fi
echo "Bundle check: ok."
