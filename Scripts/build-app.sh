#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
cd "$ROOT"

swift build -c "$CONFIG" --product Groovie
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path | tail -n 1)"

APP="$ROOT/build/Groovie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Groovie" "$APP/Contents/MacOS/Groovie"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: stable enough for local use and Automation permission prompts.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/Groovie" >/dev/null 2>&1 || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
