# Tuning

The feel of Groovie comes from a small set of numbers. Most of them live in pure types, so they
can be changed without touching the window or the renderer. This page collects the defaults and
the reasoning behind them; the interaction guide explains what each gesture does.

## Pull, pin, and skip

All values are in `Interaction/VinylLayout.swift` unless noted.

| Constant | Default | Effect |
| --- | ---: | --- |
| `pullStartDistance` | 8 pt | Movement before a pull is recognised at all. |
| `grabDetent` | 40 pt | The halfway point where the magnet snaps the record fully out. |
| `grabDistance` | 80 pt | Pointer travel corresponding to full extraction. |
| `exposurePerPoint` | 1.125 | Visible depth below the emergence line per point of pull. |
| `overscrollResistance` | 0.18 | How much a pull past full exposure can still move. |
| `mouseDismissDistance` | 30 pt | Upward movement that snaps the record back in. |
| `confirmDistance` | 240 pt | Extra pull that pins the record. |
| `scrollConfirmDistance` | 480 pt | The same distance in scroll units. |
| `confirmWindow` (`OverlayController`) | 1.0 s | Time allowed for the re-grab confirm. |
| `confirmScrubDeadzone` | 90 pt | Horizontal dead zone while confirming. |
| `scrollSkipDistance` | 90 pt | Horizontal travel required to change tracks. |
| `clickSlop` | 4 pt | Movement still treated as a click. |
| `recordRadius` | 90 pt | Record size. |
| `labelRadius` | 30 pt | Printed label size. |
| `labelHitSlop` | 12 pt | Extra play/pause hit area around the label (42 pt total radius). |
| `playbackDegreesPerSecond` | 200 | 33⅓ RPM. |
| `collapseStiffness` | 260 | Spring constant for putting the record away. |
| `collapseDamping` | 24 | Damping for the put-back spring. |
| `collapseMaximumTime` | 0.42 s | Longest collapse animation. |

The record centre is `emergenceInset + exposure - recordRadius`. At full grab the centre sits
exactly on the emergence line, which is why the visible half never drifts while scrubbing.

The magnet snap uses a 320 stiffness and 26 damping in `OverlayController`; the put-back spring
uses the 260/24 pair above.

## Music providers

`Music/PlayerCoordinator.swift` drives one `ScriptedMusicService` per player. In **auto** mode
every installed player runs: the selected one uses the normal cadence below, the other a slower
probe cadence. Pinning a player stops the other service completely, so it costs nothing. A
missing player is never started, never receives AppleScript, and is greyed out in the Player
submenu.

| Availability | Engaged | Background | Probe |
| --- | ---: | ---: | ---: |
| playing | 3 s | 5 s | 30 s |
| paused | 5 s | 10 s | 30 s |
| no track / stopped | 10 s | 15 s | 30 s |
| app not running / permission denied | 30 s | 30 s | 30 s |

Both players post a distributed playback-change notification (`com.apple.Music.playerInfo` and
the undocumented `com.spotify.client.PlaybackStateChanged`). The service debounces it for 150 ms
and reads authoritative state, so the table above is a safety net, not the primary trigger. A
probe that receives the notification polls immediately, which is why probe mode can sit at 30 s.

- Auto ranks `playing > paused > noTrack`; `permissionDenied` and `appNotRunning` both count as
  unavailable, so a denied probe never displaces a usable or current player. Uninstalled players
  are excluded. A playing tie goes to the most recent playback start, then the current provider,
  then Music when it is a candidate.
- A probe never downloads artwork. Promotion to active fetches the current cover immediately.
- **One AppleScript queue for the whole process.** AppleScript is process-global and
  `NSAppleScript` is not thread-safe; per-player queues let a Music reply arrive for a Spotify
  read, which then fails to parse. `ScriptedPlayerQueue.shared` serializes every read and command
  from both bridges.
- AppleScript commands carry a 5 s timeout. Notification-driven reads are throttled to one per
  0.5 s, and a notification that arrives inside that window schedules one follow-up read when it
  closes rather than being dropped. Three consecutive read failures drop the stale snapshot
  instead of leaving the record spinning on a phantom track.
- When the selected provider leaves playback, the other one is polled once immediately instead
  of waiting out its probe interval.
- While the record is out, a better candidate is queued instead of applied. Switching mid-gesture
  would change what the record is scrubbing and could send the seek to the wrong service; the
  queued choice is applied when the record returns.
- Artwork: Music embeds raw data in the script; Spotify supplies an HTTPS URL that
  `Music/ArtworkLoader.swift` downloads (10 s timeout, 32 MB cap, `image/*` only) and downsamples
  to 320 px with the same ImageIO path.
- On startup at most one app may launch. A player that is already running is used as-is; when
  none is running, the last player Groovie actually drove (`groovie.player.lastActive`) is
  reopened if installed. With no history, auto launches nothing.

## Notch geometry

`Notch/NotchGeometry.swift` and `StageGeometry`.

| Value | Default | Effect |
| --- | ---: | --- |
| Notch-less strip | 179 pt | Top-centre interaction width on a display without a camera housing. |
| Idle margin | 6 pt | Extra horizontal and downward hit area around the strip. |
| Stage size | 300 × 190 pt | Expanded overlay; the width grows to fit a wider physical notch. |

## Desktop records

`Desktop/DesktopRecord.swift` (geometry), `Desktop/DesktopRecordController.swift`, and
`Desktop/DesktopArtworkRenderer.swift`.

| Constant | Default | Effect |
| --- | ---: | --- |
| `discDiameter` | 180 pt | Bare record copy. |
| `coverSide` | 200 pt | Album cover side. |
| `sleeveExposed` | 72 pt | Open sleeve: 40% of the disc protrudes past the cover's right edge. |
| `sleeveOpenWidth` | 272 pt | Open sleeve item width (`coverSide + sleeveExposed`). |
| `sleeveClosedWidth` | 200 pt | Closed sleeve item width; the record is fully hidden. |
| `shadowPadding` | 34 pt | Transparent margin baked into every rendered image. |
| `cascadeStep` | 24 pt | Offset between default sleeve slots. |
| `cascadeCount` | 5 | Slots before the cascade wraps. |
| `maxRecords` | 100 | Safety cap for desktop items. |
| Fade-in | 0.18 s | One-time appearance animation; nothing runs afterwards. |

The item casts three shadow layers from one silhouette, with the light at the upper left:

| Layer | Alpha | Blur | Offset |
| --- | ---: | ---: | --- |
| Ambient | 0.10 | 38 pt | (0, −2) |
| Key | 0.26 | 16 pt | (5, −7) |
| Contact | 0.38 | 2.5 pt | (0, −1) |

An open sleeve adds a 13 pt gradient mouth shadow on the exposed vinyl, plus a board-thickness
lip and mouth slit on the cover. A closed sleeve draws no vinyl at all. Opening or closing
keeps the cover centre fixed and changes only the window's right edge.

Desktop windows always accept mouse events, so pressing Option while the pointer already rests
on an item works immediately. There is no polling timer. Option+click cycles the three desktop
presentations: open sleeve → closed sleeve → bare disc → open sleeve. Option+drag moves the
item. Without Option nothing happens: a plain click neither raises nor reorders the item.
Option-hover scales the item to 1.02 and shows an open hand; an active drag scales it to 1.04.
The outline ring appears only during a drag or while delete-armed.

Desktop windows use `CGWindowLevelForKey(.desktopIconWindow) + 1`, above the Finder desktop
icons but below normal application windows, so they stay clickable when another app is
frontmost. During a drag the item is temporarily raised to `statusBar + 2`; the delete halo is
`statusBar + 1`, and the copy ghost is `statusBar + 3`. Items opt into `.canJoinAllSpaces` so
they appear on every Space.

State lives in `~/Library/Application Support/Groovie/desktop-records.json` (document version
2, one `recordOut` flag per item), with artwork in `artwork/<uuid>.png` next to it. Loading a
version 1 file shifts each sleeve 35 pt left to the new anchor, defaults `recordOut` to true,
and rewrites the document as version 2.

## Scroll

Scroll input has no button-release event, so the policy is time-based. Values live in
`OverlayController` and `ScrollAxisLock`.

| Constant | Default | Effect |
| --- | ---: | --- |
| `scrollPullScale` | 0.55 | Scroll distance → pull distance. |
| `scrollScrubScale` | 0.9 | Scroll distance → scrub distance. |
| `scrollScrubThreshold` | 30 pt | Horizontal dead zone for a pinned scroll scrub. |
| `scrollCloseDistance` | 40 pt | Upward scroll that closes the record. |
| `scrollConfirmWindow` | 1.4 s | Idle time after which an unconfirmed scroll record returns. |
| `scrollReconfirmGap` | 0.8 s | Pause after which scrolling down again confirms. |
| `ScrollAxisLock.horizontalDominance` | 1.5× | How much wider than vertical a skip must be. |
| `ScrollAxisLock.decisionThreshold` | 0.5 pt | Travel before the scroll axis is locked. |

The axis is decided once per gesture and never flips. A skip fires once per gesture, after
`scrollSkipDistance`; this is deliberately conservative because an accidental skip is worse than
a missed one.

## Scrub sensitivity

`ScrubEngine.ScrubTuning` maps pointer speed onto a sensitivity curve instead of using a fixed
rate. The curve is defined by `minSensitivity`, `maxSensitivity`, `speedAtMaxSensitivity`, and
`sensitivityExponent`. The speed filter has a 45 ms attack and a 120 ms release, so a flick is
rewarded immediately and the extra sensitivity fades as the hand slows. Movement past the start
or end of the track is clamped in both position and rotation.

## Confirm acceleration

`ConfirmAccumulator` turns downward travel into gauge progress. A slow pull needs the full
`confirmDistance`; a fast pull multiplies each point up to 3.2×. Speed is measured against
1800 pt/s, with the same 45 ms attack and 120 ms release. Pulling back up removes the raw
distance again, and the gauge starts at zero at the moment of the snap.

## Wiggle

`WiggleDetector` requires four direction changes of at least 8 pt within one second. Tiny jitter
and a single reversal during precise scrubbing do not count.

## Haptics

| Moment | Pattern |
| --- | --- |
| Scroll gesture begins | `.levelChange` |
| Magnetic snap, pin, wiggle cancel, close | `.alignment` |

Haptics are throttled to one every 50 ms.

## First-run hint

`UI/GestureHintView.swift` and `App/AppDelegate.swift`.

| Value | Default | Effect |
| --- | ---: | --- |
| Delay after launch | 1.2 s | Lets the menu bar and overlay settle. |
| Visible duration | 7.5 s | Auto-dismiss timeout. |
| Panel size | 440 × 70 pt | Clamped to the screen width. |
| Seen flag | `groovie.gestureHintShown` | Set the first time the card is shown. |

The card ignores mouse events entirely and dismisses on the first pointer or scroll gesture.
`--gesture-hint` forces it for development.

## Status menu header

`UI/MenuHeaderView.swift` — fixed 252 × 56 pt, title width 188 pt. Long titles start a 20 pt/s
marquee after 0.7 s, with a 28 pt gap between loops. The progress bar is 2 pt tall and is
interpolated locally once per second while the menu is open.

## Brand mark and icon

`UI/BrandMark.swift` — a 20 × 11 pt optical box. The record diameter is `0.85 × 11 / 0.72`, the
notch is `1.35D × 0.22D`, and the spindle is optically corrected to a 1.1 pt minimum.

The app icon master is `docs/design/app-icon-cream-v3.png`; `Scripts/make-app-icon.sh` applies
a superellipse mask and builds `Resources/AppIcon.icns`. Sizes at or below 32 px use a cropped,
enlarged derivative of the mark.

## Stored preferences

| Key | Used by |
| --- | --- |
| `groovie.skinID` | Selected record skin. |
| `groovie.player` | Player preference: `auto`, `music`, or `spotify`. |
| `groovie.player.lastActive` | Last player Groovie drove; the only auto cold-start launch target. |
| `groovie.gestureHintShown` | Whether the first-run gesture card has been seen. |
