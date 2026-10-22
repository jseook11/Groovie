<p align="right"><a href="README.ko.md">한국어</a> · English</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/hero-dark.jpg">
    <img src="docs/assets/hero.jpg" alt="The lower half of a vinyl record emerging from the black camera housing at the top of a MacBook" width="880">
  </picture>
</p>

<h1 align="center">Groovie</h1>

<p align="center"><em>A turntable hidden in the MacBook notch.</em></p>

<p align="center">
  <a href="#requirements"><img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white&style=flat-square" alt="macOS 14 or later"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white&style=flat-square" alt="Swift 6.0"></a>
  <a href="#apple-music"><img src="https://img.shields.io/badge/Apple%20Music-driven-FA2D48?logo=applemusic&logoColor=white&style=flat-square" alt="Apple Music"></a>
  <a href="#how-it-works"><img src="https://img.shields.io/badge/dependencies-none-3DA639?style=flat-square" alt="No dependencies"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4C78A8?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#why">Why</a> ·
  <a href="#features">Features</a> ·
  <a href="#requirements">Requirements</a> ·
  <a href="#install">Install</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#development">Development</a> ·
  <a href="#tuning">Tuning</a> ·
  <a href="#known-limitations">Limitations</a> ·
  <a href="#contributing">Contributing</a>
</p>

---

Groovie turns the MacBook camera notch into a small turntable for Apple Music. The record lives
inside the notch. Pull it down and it snaps out with a magnetic detent. Grab it and turn it
sideways to seek — slowly for precision, quickly to jump. Pull once more and it stays out, ready
for play/pause and track changes. Let go and it drops back into the notch.

Everything is one physical object. There is no slider, no popover, and no window to arrange:
just a record that behaves like a record.

## Why

The notch is always black, always top-centre, and always above whatever you are doing. That makes
it the one piece of screen real estate where a skeuomorphic object can live without competing with
the desktop. Groovie treats the notch as a record sleeve and the record as the control.

Only the lower half of the record is ever visible. That is a deliberate constraint: the silhouette
reads as *a record pulled halfway out of a sleeve*, it stays inside the notch column, and it gives
the interaction an obvious resting place.

## Features

### The record

- **Pull to grab.** A vertical drag that starts in the notch begins pulling at 8 pt. At 40 pt the
  magnet takes over and the record snaps fully out with a light haptic. Release before the detent
  and it springs back.
- **Drag to rotate.** Hold the record and move sideways to turn it. Right rewinds, left
  fast-forwards, and faster gestures seek farther per point. The ends of the track clamp, so the
  record stops turning at 0:00 and at the end of the song.
- **Pin it.** While grabbed, pull 240 pt farther — or grab again within a second — and the record
  stays out. A translucent gauge under the record fills as you pull; velocity makes it fill up to
  3.2× faster. While pinning, the horizontal dead zone widens to 90 pt so a vertical pull never
  turns into an accidental seek.
- **Put it back.** Click the vinyl, drag up, or scroll up. The record springs into the notch and
  playback resumes at the chosen position. If it was paused before, it stays paused.
- **Wiggle to cancel.** Shake the record — four direction changes of 8 pt or more within one
  second — to abandon the seek and return to where you grabbed it.
- **Return to 33⅓.** When the scrub ends, manual rotation eases back into playback at 33⅓ RPM
  (200°/s).

### Playback

- **Click the label.** Once pinned, clicking the centre label toggles play/pause and the record
  stays out. The record's rotation and the UI update immediately; a short hold keeps a stale Apple
  Music poll from flipping the state back.
- **Hover hint.** On a pinned record, hovering the label darkens it, reveals a faint ❚❚ or ▶
  glyph, and changes the cursor to a pointing hand. The vinyl itself never reacts, so moving the
  pointer across the record does not make the screen flicker. The label's visible half is small,
  so the hit target is 42 pt — a 30 pt label plus 12 pt of slop.
- **Skip tracks.** A horizontal two-finger swipe over the notch, or over a pinned record's label,
  goes to the next or previous track. On the pinned record, a swipe that starts on the vinyl still
  scrubs.
- **Click the notch.** With the record closed, a single click over the notch toggles play/pause.
  With no track loaded, it brings Music forward instead.

### The notch

- **Out of the way.** The overlay is a borderless, non-activating panel one level above the status
  bar. It never steals focus or activates the app, and there is no Dock icon.
- **Works without a notch.** On displays without a camera housing, the top-centre 179 pt strip
  behaves exactly the same way.
- **First-run hint.** On a display without a notch, a small card under the strip introduces the
  hidden gestures: click to play/pause, swipe with two fingers to change tracks, pull down for the
  record. It never takes mouse events, disappears on the first gesture, and can be replayed from
  the status menu.
- **Status menu.** A fixed 252 pt header with the logo, track, artist, and progress. Long titles
  scroll after 0.7 s; short ones stay still. Only actionable states — Music closed, no track,
  permission needed — are surfaced there.
- **Five skins.** Classic black, rust, deep teal, smoke, and mono. The label always follows the
  track: album art when available, otherwise a paper label generated from the track's palette.
- **English and Korean UI**, discovered from JSON files at runtime.

### Apple Music

- Reads the current track, play state, position, duration, and artwork through AppleScript.
- Seeks with a ~100 ms target.
- Opens Music when it is not running, and brings it forward when there is no track to play.
- Explains permission problems instead of failing silently.

## Requirements

- macOS 14 Sonoma or later (developed and tested on macOS 26)
- Swift 6.0+ toolchain — Command Line Tools are enough; there is no Xcode project
- Apple Music for real playback; the built-in demo mode works without it

## Install

```sh
git clone https://github.com/jseook11/Groovie.git
cd Groovie
make app
open build/Groovie.app
```

Move `build/Groovie.app` to `/Applications` to keep it around, and add it to
**System Settings → General → Login Items** if you want it at login.

There is no installer and no notarized binary yet. The app is ad-hoc signed locally, which is
enough for development and for the Music automation prompt.

### First launch

1. Groovie appears in the menu bar. It has no Dock icon and no main window.
2. The first Music command triggers **“Groovie wants to control Music”**. Choose **Allow**.
3. If access was denied, enable it in **System Settings → Privacy & Security → Automation →
   Groovie → Music**, or use **Reconnect Music** in the status menu.
4. On a display without a notch, a one-time gesture card appears under the top-centre strip.
   Choose **Show Gesture Tips** from the status menu to see it again.

## Usage

<p align="center">
  <img src="docs/assets/gestures.svg" alt="Gesture map: hover the notch, pull down to grab, spin sideways to seek, pull once more to pin" width="1000">
</p>

For a full walkthrough of every gesture, threshold, and edge case, see the
[interaction guide](docs/ux-guide.md) (currently in Korean).

| You want to… | Mouse | Trackpad |
| --- | --- | --- |
| Wake the notch | Move the pointer over it | Move the pointer over it |
| Pull the record out | Drag down | Scroll down |
| Seek | Drag left / right while holding | Scroll left / right over the vinyl |
| Pin it out | Pull 240 pt farther, or grab again within 1 s | Keep scrolling down, or pause 0.8 s and scroll down again |
| Play / pause | Click the label (pinned) or the notch (closed) | Click the label or the notch |
| Next / previous track | — | Swipe right / left |
| Put it back | Click the vinyl, or drag up | Scroll up |
| Cancel a seek | Shake four times in one second | — |

With the record closed, the notch strip still has its own controls:

<p align="center">
  <img src="docs/assets/notch-gestures.svg" alt="Notch gestures: click to play or pause, swipe with two fingers for the previous or next track, and pull down to open the record" width="1000">
</p>

### Pull and grab

The record is rendered as a full circle; the notch cap covers its upper half so only the lower
semicircle is visible, with its centre exactly on the notch's bottom edge.

A pull is only recognised when the first movement is vertical and downward. It starts at 8 pt,
and at 40 pt the record snaps fully out. Releasing before the detent lets it spring back. Once
grabbed, the record follows the pointer, and an upward movement of 30 pt snaps it back in.

### Seek

Grab the record and move sideways. Moving right rewinds; moving left fast-forwards. Slow movement
is precise, fast movement covers more ground: the `ScrubEngine` maps pointer speed onto a
sensitivity curve instead of using a fixed rate. Movement past the start or end of the track is
clamped, and the record stops turning there too.

Until the record is pinned, a sideways drag must clear 90 pt before it starts scrubbing, so the
sideways wobble of a pin pull is ignored. On a pinned record the threshold drops to 4 pt for the
mouse and 30 pt for scroll.

### Pin and put back

A grabbed record is not pinned yet. It stays out when one of these confirm gestures happens:

- pull another 240 pt beyond the detent — a fast pull fills the gauge faster, up to 3.2×;
- release, then grab again within one second;
- with a trackpad, keep scrolling down, or stop for 0.8 s and scroll down again (480 pt of
  virtual travel, also velocity-assisted).

A translucent gauge under the record starts at zero when the record snaps out and fills as you
confirm. While confirming, horizontal movement needs 90 pt before it scrubs, so the sideways
wobble of a vertical pull is ignored.

Once pinned, click the label to toggle playback, swipe the label horizontally to change tracks,
and click the vinyl, drag up, or scroll up to close. Without a confirm gesture, the record waits
about a second after release (1.4 s for scroll) and then springs back.

### Trackpad

Scroll input has no button-release event, so the scroll policy is time-based rather than
release-based:

- **Down** pulls the record out; the halfway point snaps it open.
- **Left / right over the vinyl** scrubs, with the same speed-sensitive mapping as dragging.
- **Left / right over the notch or a pinned label** changes tracks. A skip needs 90 pt of
  horizontal travel and 1.5× horizontal dominance over vertical travel; once the gesture locks to
  an axis it cannot change its mind. A gesture can skip only once, because an unintended skip is
  worse than a missed one.
- **Up** puts the record back.
- **No input for 1.4 s** after opening puts the record back, unless it has been confirmed.
- Momentum events are ignored, so a flick does not keep scrubbing after your fingers leave the
  trackpad.

### Cancel a seek

While holding the record, shake it left and right — at least four direction changes of 8 pt or
more within one second. The seek is discarded, the position returns to where you grabbed it, and
a light haptic confirms the cancel. Small jitter or a single change of direction during precise
scrubbing does not trigger it. If the record was pinned, it stays pinned.

### Displays without a notch

On an external display, the top-centre 179 pt strip becomes the interaction area. The record
emerges from the top edge of the screen and its centre sits on that boundary, exactly as it does
inside a physical notch. When several displays are connected, the built-in notched display is
preferred.

## How it works

The interaction is a small state machine with two inputs — pointer drags and two-finger scroll —
that feed the same model:

```
idle ── hover ──► armed ── pull 8 pt ──► pulling ── detent 40 pt ──► grabbed
  ▲                                                                   │
  │                                                    drag ↔ ──► scrubbing
  │                                                                   │
  │                                        +240 pt or re-grab < 1 s   │
  │                                                                   ▼
  └────────────── click / drag up / scroll up ──────────────────── pinned
```

Some implementation details that make the physical metaphor work:

- **A panel that does not activate.** `OverlayPanel` is a borderless `NSPanel` with
  `.nonactivatingPanel`, sitting at `.statusBar + 1`. Clicking the record does not bring Groovie
  forward or change the frontmost app.
- **Input below the views.** The SwiftUI hosting view returns `nil` from `hitTest`; a transparent
  `NSView` receives every mouse event. This keeps gesture handling away from SwiftUI's layout and
  animation.
- **Two coordinate systems.** Screen events arrive with a bottom-left origin; the stage is laid out
  top-left. `contentPoint(forScreenPoint:)` converts before any hit-testing happens.
- **Hover without a key window.** Global and local `mouseMoved` monitors are combined with the
  panel's tracking area, so the label can react even though the panel never becomes key.
- **A serial bridge to Music.** Every AppleScript command goes through one queue. The position is
  estimated locally between 1.5 s polls, and a requested play state is held for up to 2 s until
  Music agrees, so a stale read cannot flip the record back.
- **One axis per scroll gesture.** `ScrollAxisLock` decides between horizontal and vertical after
  0.5 pt of travel and keeps that decision until the gesture ends. It is a pure value type, which
  makes the tricky part of track skipping straightforward to test.

### Project layout

```
Sources/GroovieKit/
  App/AppDelegate.swift                 menu-bar app, status menu, permissions
  Notch/NotchGeometry.swift             notch/no-notch detection, window frames
  Notch/OverlayPanel.swift              non-activating overlay panel and input view
  Interaction/VinylLayout.swift         state types, pull/exposure curve, geometry
  Interaction/ScrubEngine.swift         velocity-sensitive scrub math and clamping
  Interaction/ScrollAxisLock.swift      horizontal/vertical axis locking for scroll
  Interaction/ConfirmAccumulator.swift  pin gauge and velocity assistance
  Interaction/WiggleDetector.swift      shake-to-cancel detection
  Interaction/OverlayController.swift   gesture state machine, windows, springs
  Interaction/VinylViewModel.swift      state published to the UI
  Music/AppleMusicBridge.swift          AppleScript execution, seek merging, artwork
  Music/AppleMusicService.swift         polling, availability, artwork cache
  UI/VinylSkin.swift                    record palettes, persistence, track colors
  UI/RecordTexture.swift                grooves, bands, runout, label print
  UI/VinylStageView.swift               SwiftUI stage, hover hint, confirm gauge
  UI/GestureHintView.swift              first-run gesture card and its panel
  UI/BrandMark.swift                    notch + record menu-bar template mark
  UI/MenuHeaderView.swift               fixed-width header, marquee, progress
  Localization/                         language discovery and typed string keys
  Resources/Localization/               en.json, ko.json
  Debug/                                demo player and self-checks
Resources/Info.plist                    LSUIElement, automation description, icon
Resources/AppIcon.icns                  packaged macOS app icon
docs/assets/                            README images and gesture map
docs/design/                            app-icon master art
docs/localization/                     translation guide, JSON schema, key context
docs/ux-guide.md                       full interaction guide (Korean)
docs/record-crate.md                   design note: record crate / playlists (unbuilt)
docs/record-break.md                   rejected alternative: breaking the record
Scripts/                                app bundling, icon generation, localization checks
```

No third-party packages. The app is a SwiftPM executable plus a library target, bundled into an
`.app` by `Scripts/build-app.sh`.

## Development

```sh
make app        # build build/Groovie.app (release)
make run        # build and launch
make test       # headless interaction checks
make demo       # run the demo sequence and capture build/demo.png
make icon       # regenerate Resources/AppIcon.icns
make l10n-check # validate the language files
```

`make test` builds the app and runs it with `--self-test`, then checks that every language file
has the same keys and placeholders. There is no XCTest target: the interaction rules are pure
values and are checked directly, which keeps the tests fast and independent of the window server.

### Development flags

```sh
open build/Groovie.app --args --fake-music
open build/Groovie.app --args --fake-music --demo
open build/Groovie.app --args --fake-music --simulate-no-notch
open build/Groovie.app --args --fake-music --demo --skin=rust
open build/Groovie.app --args --gesture-hint
```

| Flag | What it does |
| --- | --- |
| `--fake-music` | Uses a demo player with three tracks instead of Music. |
| `--demo` | Plays a pull → rewind → fast-forward → release sequence automatically. |
| `--simulate-no-notch` | Shows the no-notch layout on a notched Mac. |
| `--gesture-hint` | Forces the first-run gesture card, even on a notched display. |
| `--skin=<id>` | Pins one of `classic`, `rust`, `teal`, `smoke`, `mono` for this run. |
| `--long-title` | Makes the demo title long enough to exercise the menu-header marquee. |
| `--lang=<code>` | Pins the UI language for this run, e.g. `en` or `ko`. |
| `--self-test` | Runs the headless checks and exits. |

### Localization

The UI follows the system language. English and Korean ship by default, and each language is a
single JSON file in `Sources/GroovieKit/Resources/Localization/`. Adding a file is enough to make
a language discoverable.

```sh
swift Scripts/new-language.swift ja "日本語"
make l10n-check
make app
open build/Groovie.app --args --lang=ja
```

See [docs/localization/README.md](docs/localization/README.md) for the translation rules and
[docs/localization/keys.md](docs/localization/keys.md) for the context of each key. Both are
currently written in Korean.

## Tuning

Most of the feel lives in a handful of constants.

| Constant | Default | Effect |
| --- | ---: | --- |
| `pullStartDistance` | 8 pt | Movement before a pull is recognised. |
| `grabDetent` | 40 pt | The halfway point where the record snaps out. |
| `grabDistance` | 80 pt | Pointer travel that corresponds to full extraction. |
| `confirmDistance` | 240 pt | Extra pull that pins the record. |
| `scrollConfirmDistance` | 480 pt | The same distance in scroll units. |
| `confirmScrubDeadzone` | 90 pt | Horizontal dead zone while confirming. |
| `mouseDismissDistance` | 30 pt | Upward movement that snaps the record back in. |
| `scrollSkipDistance` | 90 pt | Horizontal travel required to change tracks. |
| `clickSlop` | 4 pt | Movement still treated as a click. |
| `recordRadius` | 90 pt | Record size. |
| `labelRadius` | 30 pt | Printed label size. |
| `labelHitSlop` | 12 pt | Extra play/pause hit area around the label. |
| `playbackDegreesPerSecond` | 200 | 33⅓ RPM. |
| `ScrollAxisLock.horizontalDominance` | 1.5× | How much wider than vertical a skip must be. |
| `ScrollAxisLock.decisionThreshold` | 0.5 pt | Travel before the scroll axis is locked. |
| `confirmWindow` | 1.0 s | Time allowed for the re-grab confirm. |

Scroll feel is split across `scrollPullScale` (0.55), `scrollScrubScale` (0.9), the 30 pt
pinned-scrub dead zone, and the 40 pt close distance in `OverlayController`. Scrub sensitivity
lives in `ScrubEngine.ScrubTuning` (`minSensitivity`, `maxSensitivity`, `speedAtMaxSensitivity`,
and `sensitivityExponent`), with 45 ms attack and 120 ms release on the speed filter. Record skins
are palettes in `VinylSkin`; the selected skin is stored under `groovie.skinID` in `UserDefaults`.

## Known limitations

- Scroll input has no release event, so an unconfirmed record returns after 1.4 s of inactivity
  rather than when the fingers leave the trackpad.
- Seeking targets 100 ms, but Apple Music does not guarantee that precision on every track or
  stream.
- Album art comes from Music's raw artwork data. If that read fails, a generated paper label is
  used instead.
- On a display without a notch, the open stage covers the top-centre part of the menu bar while
  the record is out.
- The pointer is not visible over a physical notch. Aim for the top-centre of the screen when
  starting a drag.
- Apple Music only. Spotify's AppleScript does not expose seek, which the whole interaction
  depends on.
- Rebuilding changes the ad-hoc signature, so macOS may ask for Automation permission again during
  development.

## Contributing

Issues and pull requests are welcome. Run `make test` before sending a change. If you add a
user-facing string, add it to every language file and run `make l10n-check`.

The interaction rules live in pure types (`ScrubEngine`, `ScrollAxisLock`, `ConfirmAccumulator`,
`WiggleDetector`), and the self-checks exercise them directly. Keeping new logic at that level
makes it testable without a window server.

## License

[MIT](LICENSE) © Groovie contributors.

Groovie is an independent project and is not affiliated with Apple Inc. Apple Music is a trademark
of Apple Inc.
