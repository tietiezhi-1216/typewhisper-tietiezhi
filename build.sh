#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${TYPEWHISPER_APP:-/Applications/TypeWhisper.app}"
SDK_BINARY="$APP/Contents/Frameworks/TypeWhisperPluginSDK.framework/TypeWhisperPluginSDK"
[[ -f "$SDK_BINARY" ]] || { echo "TypeWhisper SDK not found: $APP" >&2; exit 1; }
if [[ ! -d upstream/.git ]]; then
  git clone --depth 1 --branch v1.7.1 https://github.com/TypeWhisper/typewhisper-mac.git upstream
fi
[[ $(git -C upstream rev-parse HEAD) == 2137334f7f70a92f154b4f6e2ecfa737c9da7f3f ]] || {
  echo "Expected the pinned v1.7.1 SDK source checkout." >&2; exit 1;
}
HOST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p build/link build/slices
ln -sf "$SDK_BINARY" build/link/libTypeWhisperPluginSDK.dylib
BUNDLE="build/tietiezhi.bundle"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
for ARCH in arm64 x86_64; do
  mkdir -p "build/sdk/$ARCH"
  # Compile SDK metadata only; the host supplies the runtime framework.
  swiftc -emit-module -parse-as-library -module-name TypeWhisperPluginSDK \
    -target "$ARCH-apple-macos14.0" \
    upstream/TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/*.swift \
    -emit-module-path "build/sdk/$ARCH/TypeWhisperPluginSDK.swiftmodule" 2>"build/sdk-$ARCH.log"
  swiftc -emit-library -O -swift-version 6 -module-name MiMoASRPlugin \
    -target "$ARCH-apple-macos14.0" -I "build/sdk/$ARCH" -L build/link -lTypeWhisperPluginSDK \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/*.swift -o "build/slices/tietiezhi-$ARCH"
done
lipo -create build/slices/tietiezhi-arm64 build/slices/tietiezhi-x86_64 -output "$BUNDLE/Contents/MacOS/tietiezhi"
cp manifest.json THIRD_PARTY_NOTICES.md LICENSE "$BUNDLE/Contents/Resources/"
python3 - "$BUNDLE/Contents/Info.plist" <<'PY'
import json,plistlib,sys
manifest=json.load(open('manifest.json'))
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier=manifest['id'], CFBundleName=manifest['name'],
                      CFBundleExecutable='tietiezhi',CFBundlePackageType='BNDL',
                      CFBundleVersion='4',CFBundleShortVersionString=manifest['version'],
                      NSPrincipalClass=manifest['principalClass'],LSMinimumSystemVersion='14.0'),f)
PY
codesign --force --sign - "$BUNDLE"
python3 upstream/scripts/check_plugin_sdk_symbol_compatibility.py \
  --plugin-binary "$BUNDLE/Contents/MacOS/tietiezhi" \
  --build-sdk "$SDK_BINARY" --host-sdk "$SDK_BINARY" --min-host-version "$HOST_VERSION"
echo "Built $BUNDLE (Apple Silicon + Intel)"
