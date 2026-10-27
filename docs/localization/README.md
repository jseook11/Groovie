# Localization

Umak ships with English and Korean. Each language is a single JSON file, and
adding one requires no Swift changes:

```
Sources/UmakKit/Resources/Localization/
  en.json   ← reference language
  ko.json
  xx.json   ← your language
```

At launch Umak scans the directory, matches the system language list, and
falls back to English for any missing key. `en.json` is the source of truth.

## Add a language

```sh
swift Scripts/new-language.swift ja "日本語"
```

The script copies `en.json`, sets `language`, `name`, `fallback`, and
`complete: false`, and keeps English values as placeholders. Then:

1. Translate the values in `ja.json`.
2. Keep every key and every `%1$@` / `%2$@` placeholder unchanged.
3. Run `make l10n-check`.
4. Build and try it:
   ```sh
   make app
   open build/Umak.app --args --lang=ja
   ```
5. When every key is translated, set `"complete": true`.

You can also copy `en.json` by hand. The file name and the `language` field must
match (`pt-BR.json` contains `"language": "pt-BR"`).

## File format

```json
{
  "language": "ko",
  "name": "한국어",
  "fallback": "en",
  "complete": true,
  "strings": {
    "menu.enable": "활성화",
    "a11y.headerTitleArtist": "Umak, %1$@, %2$@"
  }
}
```

- `language` — BCP 47 tag; also the fallback matching key (`ko-KR` → `ko`).
- `name` — language name in that language.
- `fallback` — language used for missing keys; normally `en`.
- `complete` — `true` only when all English keys are translated.
- `strings` — flat key/value map. See [keys.md](keys.md) for context.

## Rules

- **Keys are stable.** Never translate or rename a key; only change values.
- **Placeholders are positional.** Use `%1$@`, `%2$@` so word order can differ.
  The number and order must match `en.json`.
- **Do not translate:** the brand name `Umak`, skin IDs, track titles or
  artist names, and the names of other apps (leave `Music` as the platform
  calls it, or use your language's name for it consistently).
- Newlines are allowed (`\n`).
- Empty values are rejected.

## Packaging

`Scripts/build-app.sh` copies the language files into the app twice:

```
Umak.app/Contents/Resources/Umak_UmakKit.bundle/Contents/Resources/Localization/
Umak.app/Contents/Resources/Localization/
```

The loose `Contents/Resources/Localization/` copy is checked first. For quick
experiments you can drop a translated JSON file there and relaunch the app
without rebuilding. Editing a signed bundle invalidates its signature, so
rebuild and re-sign before distributing.

Keys beginning with `info.` are also written to
`Contents/Resources/<language>.lproj/InfoPlist.strings` at build time, which is
how the macOS Automation permission prompt is localized.

## Testing

```sh
make l10n-check     # key parity, placeholders, metadata
make test           # --self-test also checks bundled en/ko
make app
open build/Umak.app --args --lang=en
open build/Umak.app --args --lang=ko
```

`make l10n-check` reports missing keys in incomplete languages as warnings. Run
it with `--strict` if you want warnings to fail, for example in CI:

```sh
swift Scripts/check-localizations.swift \
  Sources/UmakKit/Resources/Localization --strict
```

Layout note: the status menu header is a fixed 252 pt wide (188 pt of text).
Very long translations may scroll or truncate; check the menu after translating.

## Checklist

- [ ] File name matches `language`.
- [ ] All English keys are present (or `complete` stays `false`).
- [ ] Placeholders match `en.json`.
- [ ] `make l10n-check` passes.
- [ ] Menu, header status, confirm gauge, permission alert, and accessibility
      labels were checked in the running app.
