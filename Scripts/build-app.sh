#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
UNIVERSAL="${UNIVERSAL:-0}"
cd "$ROOT"

BUILD_ARGS=(-c "$CONFIG")
if [ "$UNIVERSAL" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}" --product Groovie
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path | tail -n 1)"

APP="$ROOT/build/Groovie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Groovie" "$APP/Contents/MacOS/Groovie"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM resource bundle: Bundle.module resolves this from Contents/Resources.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

# Ship language files as loose data as well, so a translation can be tested by
# dropping a JSON file into the built app without rebuilding.
LOCALIZATION_DIR="$ROOT/Sources/GroovieKit/Resources/Localization"
if [ -d "$LOCALIZATION_DIR" ]; then
    mkdir -p "$APP/Contents/Resources/Localization"
    cp "$LOCALIZATION_DIR"/*.json "$APP/Contents/Resources/Localization/"
    swift "$ROOT/Scripts/generate-info-plist-strings.swift" \
        "$LOCALIZATION_DIR" "$APP/Contents/Resources"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: stable enough for local use and Automation permission prompts.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/Groovie" >/dev/null 2>&1 || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
