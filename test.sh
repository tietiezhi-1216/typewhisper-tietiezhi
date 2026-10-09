#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${TYPEWHISPER_APP:-/Applications/TypeWhisper.app}"
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos14.0 \
  -I build/sdk -L build/link -lTypeWhisperPluginSDK \
  -Xlinker -rpath -Xlinker "$APP/Contents/Frameworks" \
  Sources/MiMoCore.swift Tests/Tests.swift -o build/tests
./build/tests
