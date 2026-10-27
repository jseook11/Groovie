# Umak Phase 1–2 performance patch plan (rev. 2)

Status: revised after two adversarial codex reviews (rev.1 "reject as written"; rev.2 "approve with changes"). The five rev.2 corrections are incorporated. Do not implement until approved.

## Scope rule

Phase 1 and Phase 2 only. Do not add diagnostics frameworks, dependency injection, fake bridges, render-handle registries, or a 24-hour soak harness in these phases. Fix what is needed to ship the two phases safely; defer everything else to Phase 3/4.

## Codex review disposition

The first review returned "reject as written". Disposition of each blocking item:

| Codex finding | Disposition |
|---|---|
| 1. Poll completion can mutate state/re-arm after stop | **Accept.** Add a lifecycle generation and check it before applying a result or scheduling. Small, in scope. |
| 2. `pollNow()` is dropped while a read is in flight; post-command confirmation can wait 15 s | **Accept.** Add a coalesced `needsImmediatePoll` flag; completion drains it before scheduling. Reschedule when engagement changes. |
| 3. Split core/metadata contract breaks empty PID, stopped state, duration validation | **Avoid the risk entirely.** Do not split the script. Use `properties of current track` in the existing single script (verified below). |
| 4. Delayed metadata leaves the previous track interactive | **Avoided** by the same change: metadata and identity still arrive atomically in one read. |
| 5. Async texture render or artwork completion can repopulate a purged cache | **Accept the small part, reject the framework.** Add `guard started` to the artwork completion and clear published artwork in `stop()`. Treat a single in-flight texture as a bounded residual (≤ ~1.1 MB); do not add per-producer generations/locks. |
| 6. Music-running cache has no recovery if a notification is missed | **Accept a simplified fix.** Do not stop scheduling when Music is absent; use the 30 s unavailable cadence and reconcile `musicIsRunning` on each scheduled tick. No notification-only recovery hole. |
| 7. Progress timer guard does not stop an existing timer; method is `setContent` | **Accept.** Add an explicit `isActive` flag and one `syncTimers()` used by `setActive`, `setContent`, `setStatus`, and `viewDidMoveToWindow`. |
| 8. Queued click can rebuild a window after disable; deletion-key tracking is incomplete | **Accept the guard, reject the key tracking.** Add `guard isEnabled` to `toggleRecordState`/click path. Use a broad `DesktopArtworkRenderer.purge()` on delete instead of tracking per-record keys. Persist window positions before teardown. Accept that 0.18 s animated-deletion windows retire on their own completion. |
| 9. Measurements/claims overstated | **Accept.** Mark estimates as idealized; acceptance is measured, not code-derived. |

Deferred on purpose (not Phase 1/2): render-key/variant registries, texture-cache producer generations, fake clock/bridge test harness, retiring-window registry, 24-hour soak test, global hover-monitor removal, 60 Hz tick start-condition rework, desktop-record visibility materialization, shadow/scale changes, artwork cap changes.

---

## Measured baseline

- `phys_footprint` 68 MB, peak 84 MB; RSS 33 MB idle / 56 MB in use.
- CPU time 6.86 s over 4 m 45 s ≈ 2.4% average; 0.8–1.8% while interacting.
- 11 windows: 10 desktop records (268×268 pt) + overlay (300×190 pt).
- `leaks`: 288 allocations / 14,400 bytes (framework-level).
- Poll: 1.5 s repeating timer, 8–9 AppleScript property reads per tick. Idealized ~57,600 executions/day while enabled.

These are point-in-time measurements, not guarantees. Post-patch acceptance uses the same commands.

---

# Phase 1 — reclaim memory, remove cheap wakeups

## P1.1 Add explicit cache purge paths

### APIs (additive only)

- `UI/RecordTexture.swift`: `static func purge()` → clear `textureCache` and `baseCache`.
- `Desktop/DesktopArtworkRenderer.swift`: `static func purge()` → clear `cache`.
- `UI/VinylStageView.swift`: convert `HoverLayerView.imageCache: [String: CGImage]` to a 2-entry `NSCache<NSString, CGImage>` **or** add an internal `static func purgeCache()`. No unbounded dictionary may remain.

### Call sites

- `Interaction/OverlayController.swift:163-174` (`deactivate`):
  - `model.artwork = nil`
  - `RecordTexture.purge()`
  - hover cache purge
- `Music/AppleMusicService.swift:82-96` (`stop`):
  - keep the single published `artwork` reference (≤ ~0.4 MB); clear only the cache. This avoids a restart-on-the-same-track path with no cover.
  - add a lifecycle generation (used by Phase 2 as well): `private var lifecycleGeneration = 0`, incremented in `start()` and `stop()`. Capture it when an artwork request begins and require `generation == lifecycleGeneration && started && !permissionDenied` before the completion mutates `artwork`, the cache, or `artworkRequestTrackID` (`:439-471`).
  - in `handle`, after the existing track-change branch (`:288-290`), add `else if artwork == nil { updateArtwork(for: trackID) }` so a restart on the same track reacquires the cover.
- `Desktop/DesktopRecordController.swift:63-81` (`setActive(false)`):
  - persist the live anchor for each window (`DesktopRecordGeometry.anchor(windowOrigin:style:recordOut:)`) before teardown, so an in-progress drag is not lost
  - `cancelDrag`, `orderOut`, `close` each window
  - `windows.removeAll()`, `artworkByID.removeAll()`
  - `DesktopArtworkRenderer.purge()`
  - `RecordTexture.purge()`
- `Desktop/DesktopRecordController.swift:48-61` (`stop`): add both purges.
- `Desktop/DesktopRecordController.swift:351-384` (`delete`): call `DesktopArtworkRenderer.purge()` (broad purge; deletion is rare and this avoids incomplete key tracking).
- `Desktop/DesktopRecordController.swift:386-400` (`deleteAll`): both purges.
- `Desktop/DesktopRecordController.swift:93-100` (`refreshSkins`): purge the renderer cache before the repaint; old entries are keyed by the old skin.

### Guards

- Add `guard isEnabled else { return }` at the start of `toggleRecordState(id:)` (`Desktop/DesktopRecordController.swift:224`) and in the queued click closure (`:562-566`) so a click queued before disable cannot recreate a hidden window.

### Acceptance

- After disable: `windows.isEmpty`, `artworkByID.isEmpty`, renderer cache has no desktop entries. A single in-flight texture may remain until it is evicted (bounded, ≤ ~1.1 MB); do not treat that as a failure.
- Disable → enable restores once, no duplicate windows, no stale covers, and a mid-drag position survives.
- Delete one record → no composed image for it is reusable; re-enable/reopen renders once.

### Risk

- Re-enable pays ~5–10 ms/record render cost, spread one record per run-loop turn (already the restore design).
- Purging the shared texture cache may force one ~10 ms notch re-render. Acceptable.

## P1.2 Cache the Music-running state

- Add `private var musicIsRunning = false`.
- Refresh it once in `start()`, `refresh()`, and on `NSWorkspace.didWakeNotification`.
- Launch observer sets `true`; terminate observer sets `false`.
- `pollNow()` reads the cached value; remove the per-tick LaunchServices lookup.
- With the Phase 2 scheduler, the unavailable cadence is 30 s and each tick refreshes the cached value, so a missed notification cannot suppress reads forever.
- `launchMusicIfNeeded()` / `presentPlayer()` may still query directly (user actions).

Acceptance: Music quit for 5 s → no repeated LaunchServices lookups; Music relaunch → reads resume within one cadence.

## P1.3 Timer hygiene

- `Interaction/OverlayController.swift:1575-1585`: `timer.tolerance = 1.0 / 240.0`. Keep the existing start/stop conditions; do not rework them in this phase.
- `UI/MenuHeaderView.swift:271-277` (marquee): `timer.tolerance = 0.002`.
- `UI/MenuHeaderView.swift:294-301` (progress):
  - add `private var isActive = false`; `setActive` sets it.
  - add `private func syncTimers()`: **both** timers require `isActive && window != nil`. Then start the marquee only under the existing overflow/reduce-motion conditions (`:263-270`), and start the progress timer only when `isPlaying && trackDuration > 0`; otherwise invalidate each.
  - call `syncTimers()` from `setActive` (`:124-132`), `setContent` (`:64-98`), `setStatus` (`:100-121`), and `viewDidMoveToWindow` (`:326-333`).
  - `progressTimer.tolerance = 0.25`.

Acceptance: menu open + paused has no progress timer; paused → playing starts it; close/reattach leaves no timer.

## P1.4 Remove the duplicate hover monitor

- Delete the local `.mouseMoved` monitor (`Interaction/OverlayController.swift:881-884`) and its entry in `hoverMonitors`.
- Keep the global monitor. It is installed only while latched and already has a panel-frame coordinate gate (`:898-909`). Defer removal/occlusion work to Phase 3.
- Verify with the app inactive and the record latched: in-panel hover still updates from the panel tracking area.

## P1.5 Verification

- `make test`.
- Manual: overlay disable/enable; desktop disable/enable; delete one; delete all; skin change; quit/relaunch; disable during a drag.
- `footprint` and `sample` before/after; acceptance is a stable plateau over repeated cycles, not an exact allocator baseline.

---

# Phase 2 — reduce poll cost

## P2.1 Adaptive one-shot scheduler (with lifecycle guard)

Replace the repeating 1.5 s timer (`Music/AppleMusicService.swift:147-153`) with one one-shot timer at a time.

### State

- `private var pollActivity: PollActivity` (`.engaged` / `.background`).
- Reuse `lifecycleGeneration` from Phase 1 (incremented in `start()` and `stop()`); do not add a second generation counter.
- `private var needsImmediatePoll = false`.
- `private var scheduledPoll: Timer?`.
- `private var musicIsRunning` from P1.2.

### Cadence

| Music state | Engaged | Background |
|---|---|---|
| playing | 3 s | 5 s |
| paused | 5 s | 10 s |
| noTrack | 10 s | 15 s |
| appNotRunning / unknown | 30 s | 30 s |

- The unknown/unavailable row still schedules, but each tick only reconciles `musicIsRunning` and skips AppleScript if Music is absent. This is the recovery path for missed notifications.
- Permission denied: stop scheduling (existing behavior).

### Scheduling rules

- `pollNow()`: if `!started` or permission-denied, return. If a read is in flight, set `needsImmediatePoll = true` and return. Otherwise: if Music is known to be absent, run `applyNotRunning()` and `scheduleNextPoll()` without an AppleScript read. Otherwise cancel `scheduledPoll`, capture `lifecycleGeneration`, start the read.
- Completion (on MainActor):
  - if this completion's generation matches, **clear `readInFlight` first** (even when the result must be rejected), then guard `started, generation == lifecycleGeneration, !permissionDenied` before any state mutation.
  - apply the result.
  - if `needsImmediatePoll { needsImmediatePoll = false; pollNow() }` else `scheduleNextPoll()`.
  - if scheduling is rejected, ensure no timer remains and no coalesced flag is left set.
- `scheduleNextPoll()`: require `started && !permissionDenied`; invalidate any existing timer, create a one-shot `Timer(timeInterval: interval, repeats: false)`, `tolerance = min(0.3, interval * 0.2)`, add to `.common`, set `scheduledPoll`.
- `handlePermissionDenied()`: increment `lifecycleGeneration`, cancel `scheduledPoll`, clear `readInFlight` and `needsImmediatePoll`, then mark permission denied. `refresh()` starts a fresh generation, so polling can resume.
- `setOverlayEngaged(_:)`: update the flag; if engaged, call `scheduleNextPoll()` (shortens a pending background wait); if background, schedule with the background interval. Add the requirement to `MusicProviding` with a default no-op extension so `DemoMusicService` and other providers compile unchanged.
- Call sites: `OverlayController.showStage()`/`latchRecord()` → `true`; `hideStage()`/`finishCollapse()`/`vanishImmediately()`/`deactivate()` → `false`. On provider swap (`:1790-1817`), set the engaged state on the new provider.
- Add `NSWorkspace.didWakeNotification`: refresh `musicIsRunning`, then `pollNow()`.
- Launch observer: set `musicIsRunning = true`, then `pollNow()`.
- Terminate observer: set `false`, run `applyNotRunning()`, then `scheduleNextPoll()` at the unavailable cadence. Never leave polling permanently off; a missed launch notification must recover within 30 s. A read that was in flight at termination is rejected by the generation check (terminate increments `lifecycleGeneration`, or the `.notRunning` result is applied without overwriting `applyNotRunning()`).
- Keep `.common` to preserve menu-tracking behavior.

### Why this does not regress commands

Command completions (`finishScrub`, `togglePlayback`, `skip`) call `pollNow()`. With the coalesced flag, a read requested during an in-flight poll runs immediately after it, not at the next 15 s tick. `pendingPlaybackWindow` stays 2 s and is still satisfied.

Acceptance assertions:
- At most one scheduled timer and one in-flight read.
- Closing/opening the overlay reschedules immediately (no stale long wait).
- Stop/start or permission denial during a read cannot mutate state, refill caches, or re-arm a timer.

## P2.2 Collapse the metadata property reads (single script, no split)

Verified directly against the running Music app during planning: `osascript -e 'tell application "Music" to get properties of current track'` returned name, artist, album, duration, and persistent ID in one result. (The codex sandbox could not reach Music/XPC, so its live check failed; this host-level check succeeded.) Replace the per-property reads in `Music/AppleMusicBridge.swift:342-366` with that record, keeping the existing output order so `parse` (`:95-118`) is unchanged.

New body (same delimiters and output fields):

```applescript
tell application "Music"
    if it is running then
        set stateText to (player state as string)
        try
            set p to properties of current track
            set trackPersistentID to (persistent ID of p) as text
            set trackName to (name of p) as text
            set trackArtist to (artist of p) as text
            set trackAlbum to (album of p) as text
            set trackDuration to (duration of p) as real
            set playerPositionSeconds to (player position) as real
        on error
            return "NOTRACK"
        end try
        set positionMilliseconds to (playerPositionSeconds * 1000) as integer
        set durationMilliseconds to (trackDuration * 1000) as integer
        set fieldSeparator to (ASCII character 31)
        return stateText & fieldSeparator & (positionMilliseconds as text) & fieldSeparator & trackPersistentID & fieldSeparator & trackName & fieldSeparator & trackArtist & fieldSeparator & trackAlbum & fieldSeparator & (durationMilliseconds as text)
    else
        return "NOTRUNNING"
    end if
end tell
```

Notes:
- If `current track` is `missing value`, `properties of` errors → `NOTRACK`, same as today.
- A stopped player that still has a selected track returns that track's properties; the state string still reports stopped, preserving current semantics.
- Empty persistent ID is untouched: it still flows through the existing service logic.
- This removes the need for metadata state machines, PID matching, and stale-metadata handling.
- Idealized property-read reduction: 8–9 → 4 per poll (running check, state, properties record, position). Measure actual Apple Event traffic; do not claim 62.5% as a guarantee.

## P2.3 Instrumentation (minimal)

- Throttled debug logs: cadence changes, scheduled interval, coalesced immediate poll, purge calls. No new metrics subsystem.
- Measure 60 s in each of: closed + paused, closed + playing, latched + playing. Record `top -pid` CPU and one `sample 5`.
- Targets are directional: closed + paused well under the current ~2% and no LaunchServices churn; engaged + playing does not regress interaction latency.

## P2.4 Manual matrix

- play → pause → resume; external track change; external seek; skip next/prev.
- Music quit / relaunch / crash; permission denied; wake from sleep.
- Overlay pulled out and left latched; overlay closed while a read is in flight.
- Disable/enable desktop records; disable during restore; disable during a drag.
- Menu open paused → playing → paused; menu closed during a poll.

## Out of scope (unchanged)

Desktop visibility materialization, shadows, backing scale, window reuse; artwork caps; texture content keys/2x; CA marquee; disc-spin occlusion; 60 Hz tick start-condition rework; global hover removal.
