# Signing and notarization

Local builds need no Apple account. `./Scripts/build-app.sh` and `make app` sign
ad-hoc and work offline. A Developer ID signature is only needed for a release
that should open without a Gatekeeper warning.

## One-time setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/)
   and create a **Developer ID Application** certificate under
   **Certificates, Identifiers & Profiles**.
2. Download the certificate and install it in the login keychain. Confirm it is
   available with:

   ```sh
   security find-identity -v -p codesigning
   ```

   If you build on another Mac, export the certificate and key as a `.p12` and
   install it there. Never commit certificate or key material.
3. Store notary credentials in the keychain:

   ```sh
   xcrun notarytool store-credentials "umak-notary" \
       --apple-id "<apple-id>" \
       --team-id "<team-id>" \
       --password "<app-specific-password>"
   ```

   The password is an **app-specific password** generated at
   [appleid.apple.com](https://appleid.apple.com), not the account password.

## Build a signed release

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="umak-notary" \
./Scripts/package-release.sh
```

`package-release.sh` builds a universal app, signs it with the hardened runtime
and `Resources/Umak.entitlements`, notarizes a temporary zip, and staples the
ticket to the app. It then writes and hashes two artifacts:

- `build/Umak-<version>-macos-universal.zip`
- `build/Umak-<version>-macos-universal.dmg`, a drag-to-install image with an
  `/Applications` shortcut

The disk image is signed, notarized separately, and stapled, so Gatekeeper can
validate the downloaded container offline as well as the app inside it.

Set only `SIGN_IDENTITY` to sign without notarizing. Setting `NOTARY_PROFILE`
without `SIGN_IDENTITY` is an error. Running the script with neither variable
produces ad-hoc zip and DMG artifacts for local use.

The `com.apple.security.automation.apple-events` entitlement is required because
the app drives Music and Spotify through `NSAppleScript`; the hardened runtime
blocks Apple Events without it.

## What changes for users

- Developer ID signing gives TCC a stable code identity across updates, so
  Automation permission is remembered and users see fewer repeated prompts.
- A notarized, stapled app opens without the Gatekeeper warning and verifies
  offline.
- The DMG opens to the app and an Applications shortcut, so installation is a
  single drag.
- Notarization does not remove the Automation consent prompt itself. The first
  Apple Events command still asks the user for permission.
