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

## Notch geometry

`Notch/NotchGeometry.swift` and `StageGeometry`.

| Value | Default | Effect |
| --- | ---: | --- |
| Notch-less strip | 179 pt | Top-centre interaction width on a display without a camera housing. |
| Idle margin | 6 pt | Extra horizontal and downward hit area around the strip. |
| Stage size | 300 × 190 pt | Expanded overlay; the width grows to fit a wider physical notch. |

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
| `groovie.gestureHintShown` | Whether the first-run gesture card has been seen. |
