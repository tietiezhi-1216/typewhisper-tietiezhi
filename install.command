#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${TYPEWHISPER_APP:-/Applications/TypeWhisper.app}"
[[ -d "$APP" ]] || { echo "请先安装 TypeWhisper。" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
IFS=. read -r MAJOR MINOR PATCH <<< "${VERSION%%-*}"
MAJOR=${MAJOR:-0}; MINOR=${MINOR:-0}; PATCH=${PATCH:-0}
if (( MAJOR < 1 || (MAJOR == 1 && MINOR < 7) || (MAJOR == 1 && MINOR == 7 && PATCH < 1) )); then
  echo "需要 TypeWhisper 1.7.1 或更新版本，当前版本：$VERSION" >&2; exit 1
fi
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( OS_MAJOR >= 14 )) || { echo "需要 macOS 14 或更新版本。" >&2; exit 1; }
SOURCE="tietiezhi.bundle"
[[ -d "$SOURCE" ]] || SOURCE="build/tietiezhi.bundle"
[[ -d "$SOURCE" ]] || { echo "找不到 tietiezhi.bundle。源码安装请先运行 ./build.sh。" >&2; exit 1; }
codesign --verify --strict "$SOURCE"
ROOT="$HOME/Library/Application Support/TypeWhisper"
DEST="$ROOT/Plugins"
mkdir -p "$DEST"
STAGING="$DEST/.tietiezhi-install-$$"
trap 'rm -rf "$STAGING"' EXIT
# Stage and verify before changing the existing installation.
ditto "$SOURCE" "$STAGING"
codesign --verify --strict "$STAGING"
if xattr -p com.apple.quarantine "$STAGING" >/dev/null 2>&1; then
  echo "仅移除此插件的下载隔离标记（本地开发签名，未经 Apple 公证）。"
  xattr -dr com.apple.quarantine "$STAGING"
fi
BACKUP="$ROOT/PluginBackups/$(date +%Y%m%d-%H%M%S)-$$"
for OLD in MiMoASR.bundle tietiezhi.bundle; do
  if [[ -e "$DEST/$OLD" ]]; then
    mkdir -p "$BACKUP"
    mv "$DEST/$OLD" "$BACKUP/$OLD"
  fi
done
mv "$STAGING" "$DEST/tietiezhi.bundle"
echo "已安装：$DEST/tietiezhi.bundle"
echo "完全退出并重新打开 TypeWhisper，在集成中启用 tietiezhi。已有密钥与登录凭据不会删除。"
