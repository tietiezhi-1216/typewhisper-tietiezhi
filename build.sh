#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${TYPEWHISPER_APP:-/Applications/TypeWhisper.app}"
SDK_BINARY="$APP/Contents/Frameworks/TypeWhisperPluginSDK.framework/TypeWhisperPluginSDK"
HOST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [[ "$HOST_VERSION" != "1.7.1" ]]; then
  echo "This build uses SDK source v1.7.1; installed host is $HOST_VERSION. Review compatibility before rebuilding." >&2
  exit 1
fi
mkdir -p build/sdk build/link
# Generate only SDK compile-time metadata, never embed a duplicate SDK binary.
swiftc -emit-module -parse-as-library -module-name TypeWhisperPluginSDK \
  -target arm64-apple-macos14.0 \
  upstream/TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/*.swift \
  -emit-module-path build/sdk/TypeWhisperPluginSDK.swiftmodule 2>build/sdk-build.log
ln -sf "$SDK_BINARY" build/link/libTypeWhisperPluginSDK.dylib
BUNDLE="build/MiMoASR.bundle"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
swiftc -emit-library -O -swift-version 6 -module-name MiMoASRPlugin \
  -target arm64-apple-macos14.0 -I build/sdk -L build/link -lTypeWhisperPluginSDK \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/*.swift -o "$BUNDLE/Contents/MacOS/MiMoASRPlugin"
cp manifest.json "$BUNDLE/Contents/Resources/"
python3 - "$BUNDLE/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier="com.tietiezhi.typewhisper.mimo-asr",
                      CFBundleName="MiMo ASR",CFBundleExecutable="MiMoASRPlugin",
                      CFBundlePackageType="BNDL",CFBundleVersion="1",
                      CFBundleShortVersionString="0.1.0",NSPrincipalClass="MiMoASRPlugin",
                      LSMinimumSystemVersion="14.0"),f)
PY
codesign --force --sign - "$BUNDLE"
python3 upstream/scripts/check_plugin_sdk_symbol_compatibility.py \
  --plugin-binary "$BUNDLE/Contents/MacOS/MiMoASRPlugin" \
  --build-sdk "$SDK_BINARY" --host-sdk "$SDK_BINARY" --min-host-version 1.7.1
echo "Built $BUNDLE"
