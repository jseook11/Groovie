import AppKit
import Foundation
import os

/// Reads and drives Music.app over AppleScript. The service is deliberately
/// tolerant: Music may not be running, may have no track, or access may be denied.
@MainActor
final class AppleMusicService: MusicProviding {
    private(set) var nowPlaying: NowPlaying?
    private(set) var availability: MusicAvailability = .appNotRunning
    private(set) var artwork: NSImage?
    var onUpdate: (() -> Void)?

    private let bridge = AppleMusicBridge()
    private let log = Logger(subsystem: "com.groovie.app", category: "music")

    private var scheduledPoll: Timer?
    private var pollActivity: PollActivity = .background
    private var needsImmediatePoll = false
    private var started = false
    private var readInFlight = false
    private var permissionDenied = false
    private var launchInFlight = false

    private enum PollActivity {
        case engaged
        case background
    }
    /// Bumped whenever the service starts or stops. Completions from an older
    /// generation are dropped before they can touch state or re-arm work.
    private var lifecycleGeneration = 0
    /// Cached Music.app presence. Refreshed on start/refresh, workspace
    /// notifications, wake, and at most every 30 s while Music is absent, so a
    /// missed notification cannot strand polling forever.
    private var musicIsRunning = false
    private var lastRunningCheck = Date.distantPast
    /// One-shot: when the first read after starting (or reconnecting) finds no
    /// track, bring Music forward so the user can pick something to play.
    private var presentWhenNoTrack = false

    private var runningObservers: [NSObjectProtocol] = []
    private var permissionObserver: NSObjectProtocol?
    /// Music posts this on play/pause/track changes. It is only a hint to read
    /// authoritative state; the slow cadence remains the safety net.
    private var playerInfoObserver: NSObjectProtocol?
    /// One user action produces a burst of playerInfo notifications — a
    /// Stopped/Playing pair, then a few more as Music settles, then the new
    /// track's metadata — spread over roughly 200 ms. The first notification
    /// describes the state Music is leaving, and a leading-edge poll (or a
    /// throttle that drops the rest) can freeze the record on it until the
    /// next scheduled tick. Restart this one-shot on every notification so
    /// the single read happens after the burst, on the settled state.
    private var playerInfoDebounce: Timer?
    private let playerInfoDebounceInterval: TimeInterval = 0.15

    /// Only recent covers are kept: the record shows one track at a time, and
    /// the cache exists so skipping back a few tracks does not pay for another
    /// AppleScript read. A 320 px thumbnail is at most ~0.39 MB, so eight
    /// entries stay under ~3 MB.
    private let artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    /// Tracks Music has already reported without artwork, bounded so the
    /// marker cannot grow with listening time. A successful cover is not
    /// recorded here: if its thumbnail is evicted, it should be fetched again.
    private var noCoverTracks = RecentSet<String>(limit: 64)
    /// The track whose artwork request is currently running. When a skip
    /// arrives while this is set, the new track is picked up when the request
    /// finishes instead of being dropped.
    private var artworkRequestTrackID: String?
    private var lastLoggedAvailability: MusicAvailability?

    /// A click on the record flips the UI immediately. Reads that were already
    /// in flight when the command was sent can still report the old state, so
    /// hold the requested state until Music agrees or this window expires.
    private var pendingPlaybackState: Bool?
    private var pendingPlaybackDeadline: Date?
    private let pendingPlaybackWindow: TimeInterval = 2.0

    // MARK: - Lifecycle

    func start() {
        guard !started else {
            pollNow()
            return
        }
        started = true
        lifecycleGeneration += 1
        permissionDenied = false
        refreshMusicRunning()
        observeWorkspace()
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .groovieMusicPermissionDenied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePermissionDenied() }
        }
        startPolling()
        // A Music controller has nothing to drive while Music is closed, and the
        // overlay would sit inert with no explanation. Open the player instead so
        // the record works as soon as the app is available.
        presentWhenNoTrack = true
        launchMusicIfNeeded()
        pollNow()
    }

    func stop() {
        started = false
        lifecycleGeneration += 1
        scheduledPoll?.invalidate()
        scheduledPoll = nil
        readInFlight = false
        needsImmediatePoll = false
        musicIsRunning = false
        lastRunningCheck = Date()
        artworkCache.removeAllObjects()
        noCoverTracks.removeAll()
        artworkRequestTrackID = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        runningObservers.forEach { workspaceCenter.removeObserver($0) }
        runningObservers.removeAll()
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        if let playerInfoObserver {
            DistributedNotificationCenter.default().removeObserver(playerInfoObserver)
            self.playerInfoObserver = nil
        }
        playerInfoDebounce?.invalidate()
        playerInfoDebounce = nil
    }

    deinit {
        scheduledPoll?.invalidate()
    }

    func refresh() {
        permissionDenied = false
        if !started {
            start()
            return
        }
        refreshMusicRunning()
        startPolling()
        presentWhenNoTrack = true
        launchMusicIfNeeded()
        pollNow()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music"
            else { return }
            Task { @MainActor in
                self?.musicIsRunning = true
                self?.lastRunningCheck = Date()
                self?.pollNow()
            }
        }
        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music"
            else { return }
            Task { @MainActor in
                guard let self else { return }
                self.musicIsRunning = false
                self.lastRunningCheck = Date()
                // A read that was in flight when Music quit can still return a
                // track snapshot. Invalidate it before applying the stopped
                // state, or it would overwrite `applyNotRunning`.
                self.lifecycleGeneration += 1
                self.readInFlight = false
                self.needsImmediatePoll = false
                // The discarded artwork completion will never clear its marker.
                self.artworkRequestTrackID = nil
                self.applyNotRunning()
                // Keep a slow recovery tick alive; a missed launch
                // notification must not leave polling permanently off.
                self.scheduleNextPoll()
            }
        }
        let wake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMusicRunning()
                self?.pollNow()
            }
        }
        runningObservers = [launch, terminate, wake]

        playerInfoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlayerInfoNotification() }
        }
    }

    /// Coalesce the burst Music sends for one change and read once, after the
    /// last notification. The read itself is authoritative; this only removes
    /// the wait until the next scheduled poll.
    private func handlePlayerInfoNotification() {
        guard started, !permissionDenied else { return }
        playerInfoDebounce?.invalidate()
        let timer = Timer(timeInterval: playerInfoDebounceInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playerInfoDebounce = nil
                self.pollNow()
            }
        }
        // Coalescing the trailing edge with other run-loop work is fine; the
        // burst gap is much larger than this tolerance.
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        playerInfoDebounce = timer
    }

    private func startPolling() {
        guard started else { return }
        scheduleNextPoll()
    }

    /// Schedules exactly one read. A manual `pollNow()` cancels the pending
    /// timer, so there is never more than one timer or one read in flight.
    private func scheduleNextPoll() {
        scheduledPoll?.invalidate()
        scheduledPoll = nil
        guard started, !permissionDenied else { return }
        let interval = Self.pollInterval(
            engaged: pollActivity == .engaged,
            availability: availability,
            isRunning: musicIsRunning
        )
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduledPoll = nil
                self.pollNow()
            }
        }
        // Tolerance lets the run loop coalesce the read with other work.
        timer.tolerance = min(0.3, interval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        scheduledPoll = timer
    }

    /// Cadence for the next read. Kept pure so `--self-test` can verify the
    /// table instead of letting it drift silently.
    nonisolated static func pollInterval(
        engaged: Bool,
        availability: MusicAvailability,
        isRunning: Bool
    ) -> TimeInterval {
        guard isRunning else { return 30 }
        switch availability {
        // Player-info notifications cover play/pause/track changes, so the
        // engaged timer only has to recover a missed notification and resync
        // an external seek. Three seconds keeps that bound tight; five while
        // paused is enough because nothing is moving.
        case .playing: return engaged ? 3 : 5
        case .paused: return engaged ? 5 : 10
        case .noTrack: return engaged ? 10 : 15
        case .appNotRunning, .permissionDenied: return 30
        }
    }

    func setOverlayEngaged(_ engaged: Bool) {
        let next: PollActivity = engaged ? .engaged : .background
        guard next != pollActivity else { return }
        pollActivity = next
        guard started, !permissionDenied, !readInFlight else { return }
        if engaged {
            // The user is about to look at the record; refresh now instead of
            // waiting out a background interval.
            pollNow()
        } else {
            scheduleNextPoll()
        }
    }

    /// `runningApplications` materialises every app and asks LaunchServices for
    /// static information; the targeted lookup only resolves one bundle. It is
    /// cached because every poll must not pay for an XPC round trip.
    private func refreshMusicRunning() {
        musicIsRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .isEmpty
        lastRunningCheck = Date()
    }

    private func launchMusicIfNeeded() {
        refreshMusicRunning()
        guard !musicIsRunning, !launchInFlight else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else {
            return
        }
        launchInFlight = true
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.launchInFlight = false
                self.musicIsRunning = true
                self.lastRunningCheck = Date()
                // The workspace launch observer also polls, but Music can take a
                // moment to answer AppleScript. This second read covers the case
                // where the first one arrives too early.
                self.pollNow()
            }
        }
    }

    /// Bring Music forward, launching it when it is closed. The overlay has
    /// nothing to scrub without a track, so the player is where the user needs
    /// to be to start one.
    func presentPlayer() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first {
            app.activate(options: [])
        } else {
            launchMusicIfNeeded()
        }
    }

    private func presentForNoTrackIfNeeded() {
        guard presentWhenNoTrack else { return }
        presentWhenNoTrack = false
        presentPlayer()
    }

    private func applyNoTrack() {
        let changed = availability != .noTrack
        availability = .noTrack
        nowPlaying = nil
        artwork = nil
        clearPendingPlayback()
        if changed {
            logAvailabilityIfNeeded()
            onUpdate?()
        }
        presentForNoTrackIfNeeded()
    }

    // MARK: - Polling

    func pollNow() {
        guard started, !permissionDenied else { return }
        if readInFlight {
            // A command or engagement change arrived mid-read. Run once more
            // as soon as this one finishes instead of waiting out the cadence.
            needsImmediatePoll = true
            return
        }
        scheduledPoll?.invalidate()
        scheduledPoll = nil
        if !musicIsRunning {
            // Reconcile at most every 30 s in case the launch notification was
            // missed. When Music is genuinely absent this is the entire tick.
            if Date().timeIntervalSince(lastRunningCheck) >= 30 {
                refreshMusicRunning()
            }
            guard musicIsRunning else {
                applyNotRunning()
                scheduleNextPoll()
                return
            }
        }
        needsImmediatePoll = false
        readInFlight = true
        let generation = lifecycleGeneration
        bridge.read { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                // Only the request that still owns the service may clear the
                // flag or apply state. A stop/start invalidates older reads.
                guard self.started, generation == self.lifecycleGeneration else { return }
                self.readInFlight = false
                self.handle(result)
                self.finishPollCycle()
            }
        }
    }

    private func finishPollCycle() {
        guard started, !permissionDenied else {
            scheduledPoll?.invalidate()
            scheduledPoll = nil
            needsImmediatePoll = false
            return
        }
        // A read started from inside handle() owns the next cycle.
        guard !readInFlight else { return }
        if needsImmediatePoll {
            needsImmediatePoll = false
            pollNow()
        } else {
            scheduleNextPoll()
        }
    }

    private func handle(_ result: Result<AppleMusicRead, AppleMusicBridgeError>) {
        switch result {
        case .failure(let error):
            switch error {
            case .permissionDenied:
                handlePermissionDenied()
            case .notRunning:
                applyNotRunning()
            case .scriptError(let number, let message):
                log.error("Music read failed (\(number)): \(message, privacy: .public)")
            }
            return

        case .success(.notRunning):
            applyNotRunning()

        case .success(.noTrack):
            applyNoTrack()

        case .success(.track(let state, let positionMs, let persistentID, let title, let artist, let album, let durationMs)):
            let duration = Double(durationMs) / 1000
            guard duration > 0.5 else {
                applyNoTrack()
                return
            }

            let trackID = persistentID.isEmpty ? "\(title)|\(artist)" : persistentID
            let resolved = resolvedPlaybackState(reportedPlaying: state == "playing")
            let isPlaying = resolved.playing
            let snapshot = NowPlaying(
                trackID: trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                position: Double(positionMs) / 1000,
                isPlaying: isPlaying,
                sampledAt: Date()
            )

            let previousTrack = nowPlaying?.trackID
            let previousPlaying = nowPlaying?.isPlaying
            let previousAvailability = availability

            nowPlaying = snapshot
            if isPlaying {
                availability = .playing
            } else if state == "paused" || resolved.held {
                availability = .paused
            } else {
                availability = .noTrack
            }
            if availability == .noTrack {
                // A stopped player still reports the selected track, but there is
                // nothing to scrub until playback starts.
                presentForNoTrackIfNeeded()
            } else {
                presentWhenNoTrack = false
            }

            if previousTrack != trackID {
                updateArtwork(for: trackID)
            } else if artwork == nil {
                // A stop/start cycle clears the cache but keeps the track; make
                // sure the cover is fetched again instead of staying blank.
                updateArtwork(for: trackID)
            }

            let meaningfulChange = previousTrack != trackID
                || previousPlaying != isPlaying
                || previousAvailability != availability
            if meaningfulChange {
                logAvailabilityIfNeeded()
                onUpdate?()
            }
        }
    }

    /// Resolve Music's reported play state against a click that has not been
    /// confirmed yet. The requested state wins until a read agrees with it or
    /// the window expires, so a stale in-flight read cannot flip the record
    /// back for a moment.
    private func resolvedPlaybackState(reportedPlaying: Bool) -> (playing: Bool, held: Bool) {
        guard let pending = pendingPlaybackState else { return (reportedPlaying, false) }
        guard let deadline = pendingPlaybackDeadline, Date() < deadline else {
            clearPendingPlayback()
            return (reportedPlaying, false)
        }
        if reportedPlaying == pending {
            clearPendingPlayback()
            return (reportedPlaying, false)
        }
        return (pending, true)
    }

    private func clearPendingPlayback() {
        pendingPlaybackState = nil
        pendingPlaybackDeadline = nil
    }

    private func applyNotRunning() {
        musicIsRunning = false
        guard availability != .appNotRunning || nowPlaying != nil else { return }
        availability = .appNotRunning
        nowPlaying = nil
        artwork = nil
        clearPendingPlayback()
        logAvailabilityIfNeeded()
        onUpdate?()
    }

    private func logAvailabilityIfNeeded() {
        guard lastLoggedAvailability != availability else { return }
        lastLoggedAvailability = availability
        let name: String
        switch availability {
        case .appNotRunning: name = "appNotRunning"
        case .noTrack: name = "noTrack"
        case .paused: name = "paused"
        case .playing: name = "playing"
        case .permissionDenied: name = "permissionDenied"
        }
        log.debug("Music availability: \(name, privacy: .public)")
    }

    private func handlePermissionDenied() {
        guard !permissionDenied else { return }
        permissionDenied = true
        // A read or artwork request already in flight belongs to the rejected
        // generation; release its bookkeeping so refresh() can start cleanly.
        lifecycleGeneration += 1
        readInFlight = false
        needsImmediatePoll = false
        artworkRequestTrackID = nil
        playerInfoDebounce?.invalidate()
        playerInfoDebounce = nil
        availability = .permissionDenied
        nowPlaying = nil
        artwork = nil
        clearPendingPlayback()
        scheduledPoll?.invalidate()
        scheduledPoll = nil
        logAvailabilityIfNeeded()
        onUpdate?()
    }

    // MARK: - Seeking

    func finishScrub(position: Double, wasPlaying: Bool) {
        if var now = nowPlaying {
            now.position = min(max(position, 0), now.duration)
            now.sampledAt = Date()
            if now.isPlaying != wasPlaying {
                now.isPlaying = wasPlaying
            }
            nowPlaying = now
        }
        bridge.finish(position: position, wasPlaying: wasPlaying) { [weak self] in
            self?.pollNow()
        }
    }

    func togglePlayback() {
        guard var now = nowPlaying else { return }
        // Reflect the new state immediately so the record starts or stops
        // spinning without waiting for the AppleScript round trip.
        now.position = estimatedPosition(at: Date())
        now.sampledAt = Date()
        now.isPlaying.toggle()
        nowPlaying = now
        availability = now.isPlaying ? .playing : .paused
        pendingPlaybackState = now.isPlaying
        pendingPlaybackDeadline = Date().addingTimeInterval(pendingPlaybackWindow)
        onUpdate?()
        bridge.togglePlayback { [weak self] success in
            guard let self else { return }
            if !success {
                self.clearPendingPlayback()
            }
            self.pollNow()
        }
    }

    func skipToNext() {
        skip(forward: true)
    }

    func skipToPrevious() {
        skip(forward: false)
    }

    private func skip(forward: Bool) {
        guard nowPlaying != nil else { return }
        // The next track's metadata is unknown until Music answers, so read it
        // back as soon as the command completes instead of showing a guess.
        bridge.skip(toNext: forward) { [weak self] in
            self?.pollNow()
        }
    }

    // MARK: - Artwork

    private func updateArtwork(for trackID: String) {
        guard started else { return }
        if let cached = artworkCache.object(forKey: trackID as NSString) {
            artwork = cached
            return
        }
        if noCoverTracks.contains(trackID) {
            // Music already told us this track has no artwork. Drop the
            // previous cover so the texture falls back to the printed label
            // instead of leaving the old album on screen.
            artwork = nil
            return
        }
        // A request is already running. It will start the request for whichever
        // track is current when it finishes, so a quick double skip cannot
        // leave the second track without its cover.
        guard artworkRequestTrackID == nil else { return }

        artworkRequestTrackID = trackID
        let generation = lifecycleGeneration

        bridge.readArtworkThumbnail(maxPixelSize: 320) { [weak self] image in
            Task { @MainActor in
                guard let self,
                      self.started,
                      !self.permissionDenied,
                      generation == self.lifecycleGeneration
                else { return }
                // A stop/start cycle can leave an older read in flight; do not
                // clear the marker belonging to a newer request.
                if self.artworkRequestTrackID == trackID {
                    self.artworkRequestTrackID = nil
                }
                if let image {
                    self.artworkCache.setObject(
                        image,
                        forKey: trackID as NSString,
                        cost: Self.artworkCost(image)
                    )
                } else {
                    self.noCoverTracks.insert(trackID)
                }

                let currentTrackID = self.nowPlaying?.trackID
                guard currentTrackID == trackID else {
                    // The user moved on while this read was in flight. Keep the
                    // result for when they come back, and fetch the current
                    // track's artwork now.
                    if let currentTrackID,
                       self.artworkCache.object(forKey: currentTrackID as NSString) == nil,
                       !self.noCoverTracks.contains(currentTrackID) {
                        self.updateArtwork(for: currentTrackID)
                        self.onUpdate?()
                    }
                    return
                }

                self.artwork = image
                self.onUpdate?()
            }
        }
    }

    private static func artworkCost(_ image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }
}
