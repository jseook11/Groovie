#!/usr/bin/env bash
set -euo pipefail

# Builds the universal release app and writes the zip attached to a GitHub
# release. Prints the SHA-256 used in the release notes.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="$ROOT/build/Groovie.app"
ZIP="$ROOT/build/Groovie-$VERSION-macos-universal.zip"

UNIVERSAL=1 CONFIG=release "$ROOT/Scripts/build-app.sh"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Groovie")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *)
        echo "error: expected a universal binary, got: $ARCHS" >&2
        exit 1
        ;;
esac

codesign --verify --deep --strict "$APP"

rm -f "$ZIP"
# --norsrc/--noextattr keep the zip free of __MACOSX metadata entries.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

shasum -a 256 "$ZIP"
echo "Packaged $ZIP"
