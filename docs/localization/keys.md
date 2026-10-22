# String keys

Every user-facing string in Groovie. Keep the key column unchanged; translate
only the value in your language file.

| Key | English (reference) | Where it appears |
| --- | --- | --- |
| `menu.enable` | Enable | Status menu toggle |
| `menu.demo` | Play Demo | Status menu |
| `menu.skin` | Record Skin | Status menu submenu title |
| `menu.retryMusic` | Reconnect to Music | Status menu |
| `menu.openMusic` | Open Music | Status menu |
| `menu.automationSettings` | Automation Settings… | Status menu |
| `menu.quit` | Quit Groovie | Status menu |
| `skin.classic` | Classic Black | Record Skin submenu |
| `skin.rust` | Rust | Record Skin submenu |
| `skin.teal` | Deep Teal | Record Skin submenu |
| `skin.smoke` | Smoke | Record Skin submenu |
| `skin.mono` | Mono | Record Skin submenu |
| `status.noDisplay` | No available display | Menu header status |
| `status.overlayInactive` | Overlay inactive | Menu header status |
| `status.disabled` | Disabled | Menu header status |
| `status.musicNotRunning` | Music isn't running | Menu header status |
| `status.noTrack` | Nothing to play | Menu header status |
| `status.permissionRequired` | Automation permission required | Menu header status (warning) |
| `header.noTrack` | Nothing playing | Menu header title when Music has no track |
| `overlay.pullToLock` | Pull further to lock | Confirm gauge under the record |
| `alert.permissionTitle` | Groovie can't control Music | Automation permission alert title |
| `alert.permissionBody` | Allow Groovie to control Music in System Settings → Privacy & Security → Automation. | Permission alert body |
| `alert.openSettings` | Open Settings | Permission alert button |
| `alert.later` | Later | Permission alert button |
| `a11y.app` | Groovie | Menu bar item, header accessibility label |
| `a11y.headerTitle` | Groovie, %1$@ | Header accessibility label (title only) |
| `a11y.headerTitleArtist` | Groovie, %1$@, %2$@ | Header accessibility label (title and artist) |
| `a11y.headerStatus` | Groovie, %1$@ | Header accessibility label in status mode |
| `info.appleEventsUsageDescription` | Groovie controls Music to seek through the current track by turning the record in the notch. | macOS Automation permission prompt (`InfoPlist.strings`) |

## Placeholders

- `%1$@` — first argument, `%2$@` — second argument.
- Use the same placeholders as `en.json`; you may reorder them in the sentence.
- Do not translate `Groovie`; it is the app name.
