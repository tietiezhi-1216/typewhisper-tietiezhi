#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')
ROOT="build/release/tietiezhi-$VERSION"
mkdir -p "$ROOT"
ditto build/tietiezhi.bundle "$ROOT/tietiezhi.bundle"
cp install.command README.md THIRD_PARTY_NOTICES.md LICENSE "$ROOT/"
chmod +x "$ROOT/install.command"
ZIP="build/tietiezhi-$VERSION-macos-universal.zip"
# Avoid including stale archive entries on repeated packaging.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "$ZIP"
