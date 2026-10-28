# String keys

Every user-facing string in Umak. Keep the key column unchanged; translate
only the value in your language file.

| Key | English (reference) | Where it appears |
| --- | --- | --- |
| `menu.enable` | Enable | Status menu toggle |
| `menu.display` | Display | Status menu submenu title (two or more displays) |
| `menu.displayAuto` | Auto | Display submenu |
| `menu.gestureTips` | Show Gesture Tips | Status menu |
| `menu.skin` | Record Skin | Status menu submenu title |
| `menu.clearDesktopRecords` | Clear Desktop Records (%1$d) | Status menu (number of records) |
| `menu.player` | Player | Status menu submenu title |
| `menu.retryPlayer` | Reconnect to %1$@ | Status menu (active player name) |
| `menu.openPlayer` | Open %1$@ | Status menu (active player name) |
| `menu.automationSettings` | Automation Settings… | Status menu |
| `menu.checkUpdates` | Check for Updates… | Status menu, when up to date |
| `menu.checkingUpdates` | Checking for Updates… | Status menu, while a check is running |
| `menu.updateAvailable` | Umak %1$@ Available | Status menu, when a newer release exists |
| `menu.quit` | Quit Umak | Status menu |
| `skin.classic` | Classic Black | Record Skin submenu |
| `skin.rust` | Rust | Record Skin submenu |
| `skin.teal` | Deep Teal | Record Skin submenu |
| `skin.smoke` | Smoke | Record Skin submenu |
| `skin.mono` | Mono | Record Skin submenu |
| `player.auto` | Auto | Player submenu |
| `player.music` | Music | Player submenu |
| `player.spotify` | Spotify | Player submenu |
| `status.noDisplay` | No available display | Menu header status |
| `status.overlayInactive` | Overlay inactive | Menu header status |
| `status.disabled` | Disabled | Menu header status |
| `status.playerNotRunning` | %1$@ isn't running | Menu header status (active player name) |
| `status.noTrack` | Nothing to play | Menu header status |
| `status.permissionRequired` | %1$@ needs Automation permission | Menu header status (active player name, warning) |
| `header.noTrack` | Nothing playing | Menu header title when the player has no track |
| `overlay.pullToLock` | Pull further to lock | Confirm gauge under the record |
| `overlay.dropToRemove` | Drop to remove | Desktop record drag overlay |
| `hint.click.title` | Click | Gesture hint card |
| `hint.click.detail` | Play or pause | Gesture hint card |
| `hint.swipe.title` | Two-finger swipe | Gesture hint card |
| `hint.swipe.detail` | Previous · next track | Gesture hint card |
| `hint.pull.title` | Pull down | Gesture hint card |
| `hint.pull.detail` | Open the record | Gesture hint card |
| `hint.up.title` | Swipe up | Gesture hint card |
| `hint.up.detail` | Bring the app forward | Gesture hint card |
| `alert.clearDesktopRecordsTitle` | Clear desktop records? | Clear-desktop confirmation title |
| `alert.clearDesktopRecordsBody` | %1$d records on your desktop will be removed. The record in the notch and playback are not affected. | Clear-desktop confirmation body (record count) |
| `alert.clear` | Clear | Clear-desktop confirmation button |
| `alert.permissionTitle` | Umak can't control %1$@ | Automation permission alert title (player name) |
| `alert.permissionBody` | Allow Umak to control %1$@ in System Settings → Privacy & Security → Automation. | Permission alert body (player name) |
| `alert.openSettings` | Open Settings | Permission alert button |
| `alert.later` | Later | Permission and update alert button |
| `alert.ok` | OK | Update check alerts |
| `alert.updateTitle` | Update Available | Update alert title |
| `alert.updateBody` | Umak %1$@ is available. You're using %2$@. | Update alert body (latest, then current) |
| `alert.openRelease` | Open Release Page | Update alert button |
| `alert.upToDateTitle` | You're Up to Date | Manual check title when current |
| `alert.upToDateBody` | Umak %1$@ is the latest version. | Manual check body |
| `alert.updateFailedTitle` | Couldn't Check for Updates | Manual check failure title |
| `alert.updateFailedBody` | Check your internet connection and try again. | Manual check failure body |
| `a11y.app` | Umak | Menu bar item, header accessibility label |
| `a11y.headerTitle` | Umak, %1$@ | Header accessibility label (title only) |
| `a11y.headerTitleArtist` | Umak, %1$@, %2$@ | Header accessibility label (title and artist) |
| `a11y.headerStatus` | Umak, %1$@ | Header accessibility label in status mode |
| `info.appleEventsUsageDescription` | Umak controls Music and Spotify to seek through the current track by turning the record in the notch. | macOS Automation permission prompt (`InfoPlist.strings`) |

## Placeholders

- `%1$@` — first argument, `%2$@` — second argument.
- `%1$d` — first integer argument (record counts).
- Use the same placeholders as `en.json`; you may reorder them in the sentence.
- Do not translate `Umak`; it is the app name.
