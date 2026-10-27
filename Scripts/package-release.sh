#!/usr/bin/env bash
set -euo pipefail

# Builds the universal release app and writes the zip attached to a GitHub
# release. Prints the SHA-256 used in the release notes.
#
# SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)". Empty signs ad-hoc,
#                 which is enough for local use.
# NOTARY_PROFILE  notarytool keychain profile name. Requires SIGN_IDENTITY.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
# build-app.sh runs as a child process and signs when it sees this.
export SIGN_IDENTITY

if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
    echo "error: NOTARY_PROFILE requires SIGN_IDENTITY (a Developer ID Application identity)" >&2
    exit 1
fi

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

# Drop any previous asset first, so a failed notarization cannot leave an old
# zip that looks like the output of this run.
rm -f "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
    # Catch a missing/incorrect identity before spending time on a submission.
    if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'Authority=Developer ID Application'; then
        echo "error: notarization requires a Developer ID Application signature" >&2
        exit 1
    fi

    STAGE="$ROOT/build/notarize"
    TMP_ZIP="$STAGE/Groovie-$VERSION-notarize.zip"
    NOTARY_LOG="$STAGE/notarytool.log"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"

    # notarytool submits an archive, not a bundle. Staple the app afterwards so
    # the final zip below is made from the copy that carries the ticket.
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$TMP_ZIP"

    # --wait follows processing to completion. A rejected submission exits
    # non-zero, but check the final status too rather than trusting one signal.
    if ! xcrun notarytool submit "$TMP_ZIP" --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$NOTARY_LOG"; then
        echo "error: notarization submission failed (see $NOTARY_LOG)" >&2
        exit 1
    fi
    if ! grep -q 'status: Accepted' "$NOTARY_LOG"; then
        echo "error: notarization was not accepted (see $NOTARY_LOG)" >&2
        exit 1
    fi
    rm -f "$TMP_ZIP"

    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -rf "$STAGE"

    # Gatekeeper can cache an assessment from an earlier unsigned copy, so a
    # local check can fail even when the ticket is valid. Warn, do not abort.
    if ! spctl --assess --type execute --verbose "$APP"; then
        echo "warning: spctl assessment failed; verify on a clean Mac" >&2
    fi
fi

# --norsrc/--noextattr keep the zip free of __MACOSX metadata entries.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

shasum -a 256 "$ZIP"
echo "Packaged $ZIP"
