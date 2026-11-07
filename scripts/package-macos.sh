#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-$PWD/build/PoFig.app}"
if [ ! -d "$app" ]; then
  echo "Build PoFig.app first: bash scripts/build-macos.sh --universal" >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
mkdir -p build
stage="$(mktemp -d "$PWD/build/macos-package.XXXXXX")"
archive="$stage.zip"
trap 'rm -rf "$stage"; rm -f "$archive"' EXIT

# Preserve the app's signature and any future notarization ticket.
# The opening guide sits outside the app so it can be read before app approval.
ditto "$app" "$stage/PoFig.app"
cp macos/OPEN-FIRST.txt "$stage/OPEN-MAC-FIRST.txt"
cp README.md "$stage/README.md"
codesign --verify --deep --strict "$stage/PoFig.app"
python3 scripts/update-manifest.py "$stage/PoFig.app" macos "$stage/PoFig-update.json"
ditto -c -k --sequesterRsrc "$stage" "$archive"
mv -f "$archive" build/PoFig-macOS.zip
