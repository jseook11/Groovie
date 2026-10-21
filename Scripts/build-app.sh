#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
cd "$ROOT"

swift build -c "$CONFIG" --product NotchVinyl
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path | tail -n 1)"

APP="$ROOT/build/NotchVinyl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/NotchVinyl" "$APP/Contents/MacOS/NotchVinyl"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: stable enough for local use and Automation permission prompts.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/NotchVinyl" >/dev/null 2>&1 || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
