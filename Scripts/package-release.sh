#!/usr/bin/env bash
set -euo pipefail

# Builds the universal release app and writes the zip and drag-to-install DMG
# attached to a GitHub release. Prints the SHA-256 of each.
#
# SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)". Empty signs ad-hoc,
#                 which is enough for local use.
# NOTARY_PROFILE  notarytool keychain profile name. Requires SIGN_IDENTITY.
#
# When NOTARY_PROFILE is set the app is notarized through a temporary zip, then
# the DMG is signed and notarized separately, so both artifacts carry a ticket.

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
APP="$ROOT/build/Umak.app"
ZIP="$ROOT/build/Umak-$VERSION-macos-universal.zip"
DMG="$ROOT/build/Umak-$VERSION-macos-universal.dmg"

# Submit an archive or disk image and fail unless Apple accepts it.
notarize() {
    local artifact="$1"
    local log="$2"
    # --wait follows processing to completion. A rejected submission exits
    # non-zero, but check the final status too rather than trusting one signal.
    if ! xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$log"; then
        echo "error: notarization submission failed (see $log)" >&2
        return 1
    fi
    if ! grep -q 'status: Accepted' "$log"; then
        echo "error: notarization was not accepted (see $log)" >&2
        return 1
    fi
}

UNIVERSAL=1 CONFIG=release "$ROOT/Scripts/build-app.sh"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Umak")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) ;;
    *)
        echo "error: expected a universal binary, got: $ARCHS" >&2
        exit 1
        ;;
esac

codesign --verify --deep --strict "$APP"

# Drop any previous assets first, so a failed notarization cannot leave an old
# artifact that looks like the output of this run.
rm -f "$ZIP" "$DMG"

STAGE="$ROOT/build/notarize"

if [ -n "$NOTARY_PROFILE" ]; then
    # Catch a missing/incorrect identity before spending time on a submission.
    # Match in the shell rather than piping into `grep -q`: under pipefail an
    # early grep exit can SIGPIPE codesign and turn a valid signature into a
    # false failure.
    SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
    case "$SIGN_INFO" in
        *"Authority=Developer ID Application"*) ;;
        *)
            echo "error: notarization requires a Developer ID Application signature" >&2
            exit 1
            ;;
    esac

    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    TMP_ZIP="$STAGE/Umak-$VERSION-notarize.zip"

    # notarytool submits an archive, not a bundle. Staple the app afterwards so
    # the final zip and DMG are made from the copy that carries the ticket.
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$TMP_ZIP"
    notarize "$TMP_ZIP" "$STAGE/app-notarytool.log"
    rm -f "$TMP_ZIP"

    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"

    # Gatekeeper can cache an assessment from an earlier unsigned copy, so a
    # local check can fail even when the ticket is valid. Warn, do not abort.
    if ! spctl --assess --type execute --verbose "$APP"; then
        echo "warning: spctl assessment failed; verify on a clean Mac" >&2
    fi
fi

# --norsrc/--noextattr keep the zip free of __MACOSX metadata entries.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

# Drag-to-install disk image: the app plus an /Applications shortcut. A plain
# hdiutil image has no custom window layout, which is enough for a menu-bar app.
DMG_STAGE="$ROOT/build/dmg"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/Umak.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Umak" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

# Sign the image itself: Gatekeeper assesses the downloaded container too.
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"
fi

if [ -n "$NOTARY_PROFILE" ]; then
    notarize "$DMG" "$STAGE/dmg-notarytool.log"

    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    rm -rf "$STAGE"

    # As with the app, a cached assessment can fail locally even when the
    # ticket is valid. Warn, do not abort.
    if ! spctl --assess --type open --context context:primary-signature --verbose "$DMG"; then
        echo "warning: DMG spctl assessment failed; verify on a clean Mac" >&2
    fi
fi

shasum -a 256 "$ZIP" "$DMG"
echo "Packaged $ZIP"
echo "Packaged $DMG"
