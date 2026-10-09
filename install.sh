#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Library/Application Support/TypeWhisper/Plugins"
mkdir -p "$DEST"
if [[ -e "$DEST/MiMoASR.bundle" ]]; then
  mkdir -p build/backups
  mv "$DEST/MiMoASR.bundle" "build/backups/MiMoASR-$(date +%Y%m%d-%H%M%S).bundle"
fi
ditto build/MiMoASR.bundle "$DEST/MiMoASR.bundle"
codesign --verify --strict "$DEST/MiMoASR.bundle"
echo "Installed: $DEST/MiMoASR.bundle"
echo "Restart TypeWhisper when convenient, then enable MiMo ASR and save your API key."
