#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT/macos"
DIST_DIR="$ROOT/dist"
APP="$DIST_DIR/NotifyBridge.app"

echo "==> Building macOS receiver"
cd "$MACOS_DIR"
swift build -c release

echo "==> Assembling app bundle"
mkdir -p "$DIST_DIR"
if [[ -d "$APP" ]]; then
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$MACOS_DIR/.build/release/NotifyBridge" "$APP/Contents/MacOS/NotifyBridge"
cp "$MACOS_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

chmod +x "$APP/Contents/MacOS/NotifyBridge"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP"

echo "==> Done: $APP"
echo "    Open it with: open \"$APP\""
