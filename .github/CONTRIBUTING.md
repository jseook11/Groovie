# Contributing to Groovie

Thanks for taking the time to help. Groovie is a small macOS app, so the most useful
contributions are reproducible bug reports, feedback on how the interaction feels, and
localization improvements.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6.0 toolchain)
- Apple Music for end-to-end manual testing (not required for the self-checks)

## Getting started

```sh
git clone https://github.com/jseook11/Groovie.git
cd Groovie
make test
make run
```

`make test` builds the package, runs the headless self-checks, and validates every
localization file. If that passes, the setup is ready.

Useful development flags (`--fake-music`, `--demo`, `--skin=…`, `--lang=…`) are listed in
the [README](../README.md#development-flags).

## Before you send a change

1. `make test` must pass.
2. If you add or change a user-facing string, update every file in
   `Sources/GroovieKit/Resources/Localization/` and run `make l10n-check`.
3. If you change timing, thresholds, or defaults, update `docs/tuning.md`.
4. UI changes: attach a screenshot or a short screen recording to the pull request.
5. Keep interaction logic in the pure types (`ScrubEngine`, `ScrollAxisLock`,
   `ConfirmAccumulator`, `WiggleDetector`) where possible. The self-checks exercise them
   directly, without a window server.

## Commits and pull requests

- One logical change per commit, with a short imperative subject
  (`Skip tracks from notch swipes`).
- Describe the user-visible effect in the pull request, not only the implementation.
- Do not commit `build/`, `.build/`, `DerivedData/`, or any signing material.
- By contributing you agree to license your work under the project's [MIT license](../LICENSE).

## Releasing

See [docs/release.md](../docs/release.md) for Developer ID signing and
notarization. Local ad-hoc builds need no Apple account.

## Reporting bugs

Open an issue with the bug report template. Include the macOS version, Mac model (notch or
no notch), Apple Music version, the exact gesture that failed, and whether `--fake-music`
reproduces it.

## Localization

See [docs/localization/README.md](../docs/localization/README.md) for the translation rules
and [docs/localization/keys.md](../docs/localization/keys.md) for the context of each key.
Both are written in English. Adding a JSON file is enough to make a language
discoverable:

```sh
swift Scripts/new-language.swift ja "日本語"
make l10n-check
```

## Security

Please do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
