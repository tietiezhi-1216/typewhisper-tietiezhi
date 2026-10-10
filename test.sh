#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${TYPEWHISPER_APP:-/Applications/TypeWhisper.app}"
# Updater tests validate and install the actual signed archive in a temp root.
./package.sh >/dev/null
swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos14.0" \
  -I "build/sdk/$(uname -m)" -L build/link -lTypeWhisperPluginSDK \
  -Xlinker -rpath -Xlinker "$APP/Contents/Frameworks" \
  Sources/MiMoCore.swift Sources/AntigravityCore.swift Sources/AntigravityService.swift Sources/AntigravityDiagnostics.swift Sources/AntigravityModels.swift \
  Sources/OAuthLoopback.swift Sources/PluginUpdateCore.swift Sources/PluginUpdateService.swift Sources/AppShortcutCore.swift Sources/AppShortcutController.swift Tests/*.swift -o build/tests
./build/tests
