# Security policy

## Supported versions

Security fixes land on `main` and in the latest tagged release. Older versions are not
supported.

## Reporting a vulnerability

Please report security issues privately, not in a public issue.

Use GitHub's private vulnerability reporting:

<https://github.com/jseook11/Umak/security/advisories/new>

Include the affected version or commit, your macOS version, and steps to reproduce.

## Scope

Umak runs locally and contains no network code. The areas most worth scrutiny are:

- the AppleScript/Automation bridge to Music (`AppleMusicBridge`)
- parsing of track metadata and artwork returned by Music
- the accessibility and window-level behavior of the notch overlay

Issues in macOS or Apple Music itself should be reported to Apple.

## What to expect

This is a small, volunteer-maintained project. Reports are usually acknowledged within a
few days. Reporters are credited in the advisory unless they ask not to be.
