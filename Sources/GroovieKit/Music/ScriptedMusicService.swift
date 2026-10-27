import AppKit
import Foundation
import os

/// How often a service polls. `probe` is used for the provider that is running
/// but is not currently driving the record, so auto selection can notice it
/// starting without paying the active provider's cadence twice.
enum PollActivity {
    case engaged
    case background
    case probe
}

/// Reads and drives one scripted player (Music or Spotify). The service is
/// deliberately tolerant: the app may not be running, may have no track, or
/// access may be denied. Player-specific behavior lives in the bridge and the
/// descriptor; polling, lifecycle guards, artwork caching, and optimistic
/// playback state are shared.
@MainActor
final class ScriptedMusicService: MusicProviding {
    private(set) var nowPlaying: NowPlaying?
    private(set) var availability: MusicAvailability = .appNotRunning
    private(set) var artwork: NSImage?
    var onUpdate: (() -> Void)?

    let descriptor: ScriptedPlayerDescriptor
    private let bridge: any ScriptedPlayerBridge
    private let log = Logger(subsystem: "com.groovie.app", category: "music")

    /// Whether `start()`/`refresh()` may open the app when it is closed. The
    /// coordinator enables this only for the provider the user is asking for,
    /// so auto mode never launches Spotify behind the user's back.
    var launchesWhenClosed = true

    private var scheduledPoll: Timer?
    private var pollActivity: PollActivity = .background
    private var needsImmediatePoll = false
    private var started = false
    private var readInFlight = false
    private var permissionDenied = false
    private var launchInFlight = false

    /// Bumped whenever the service starts or stops. Completions from an older
    /// generation are dropped before they can touch state or re-arm work.
    private var lifecycleGeneration = 0
    /// Cached app presence. Refreshed on start/refresh, workspace
    /// notifications, wake, and at most every 30 s while the player is absent,
    /// so a missed notification cannot strand polling forever.
    private var playerIsRunning = false
    private var lastRunningCheck = Date.distantPast
    /// One-shot: when the first read after starting (or reconnecting) finds no
    /// track, bring the player forward so the user can pick something to play.
    private var presentWhenNoTrack = false

    private var runningObservers: [NSObjectProtocol] = []
    private var permissionObserver: NSObjectProtocol?
    /// Music posts this on play/pause/track changes. It is only a hint to read
    /// authoritative state; the slow cadence remains the safety net. Spotify
    /// has no equivalent and uses the cadence alone.
    private var changeObserver: NSObjectProtocol?
    /// One user action produces a burst of notifications — a Stopped/Playing
    /// pair, then a few more as the player settles, then the new track's
    /// metadata — spread over roughly 200 ms. The first notification describes
    /// the state the player is leaving, and a leading-edge poll (or a throttle
    /// that drops the rest) can freeze the record on it until the next
    /// scheduled tick. Restart this one-shot on every notification so the
    /// single read happens after the burst, on the settled state.
    private var changeDebounce: Timer?
    private let changeDebounceInterval: TimeInterval = 0.15

    /// Only recent covers are kept: the record shows one track at a time, and
    /// the cache exists so skipping back a few tracks does not pay for another
    /// read. A 320 px thumbnail is at most ~0.39 MB, so eight entries stay
    /// under ~3 MB.
    private let artworkCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    /// Tracks the player has already reported without artwork, bounded so the
    /// marker cannot grow with listening time. A successful cover is not
    /// recorded here: if its thumbnail is evicted, it should be fetched again.
    private var noCoverTracks = RecentSet<String>(limit: 64)
    /// The track whose artwork request is currently running. When a skip
    /// arrives while this is set, the new track is picked up when the request
    /// finishes instead of being dropped.
    private var artworkRequestTrackID: String?
    /// The cover URL of the current track, kept so a retry after a transient
    /// network failure does not need another read.
    private var currentArtworkURL: URL?
    /// A download failed for a reason that may heal (offline, timeout, 5xx).
    /// Retry the same track after this deadline instead of on every poll.
    private var artworkRetryTrackID: String?
    private var artworkRetryDeadline: Date?
    private let artworkRetryInterval: TimeInterval = 10
    private var lastLoggedAvailability: MusicAvailability?

    /// A click on the record flips the UI immediately. Reads that were already
    /// in flight when the command was sent can still report the old state, so
    /// hold the requested state until the player agrees or this window expires.
    private var pendingPlaybackState: Bool?
    private var pendingPlaybackDeadline: Date?
    private let pendingPlaybackWindow: TimeInterval = 2.0

    init(descriptor: ScriptedPlayerDescriptor, bridge: any ScriptedPlayerBridge) {
        self.descriptor = descriptor
        self.bridge = bridge
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else {
            pollNow()
            return
        }
        started = true
        lifecycleGeneration += 1
        permissionDenied = false
        refreshPlayerRunning()
        observeWorkspace()
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .grooviePlayerPermissionDenied,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                // Both services are alive in auto mode and the notification is
                // posted by a bridge, so only the bridge's owner may react.
                guard let self,
                      let sender = note.object as AnyObject?,
                      sender === self.bridge as AnyObject
                else { return }
                self.handlePermissionDenied()
            }
        }
        startPolling()
        // A controller has nothing to drive while its player is closed, and the
        // overlay would sit inert with no explanation. Open the player instead
        // so the record works as soon as the app is available.
        presentWhenNoTrack = true
        launchPlayerIfNeeded()
        pollNow()
    }

    func stop() {
        started = false
        lifecycleGeneration += 1
        scheduledPoll?.invalidate()
        scheduledPoll = nil
        readInFlight = false
        needsImmediatePoll = false
        playerIsRunning = false
        lastRunningCheck = Date()
        artworkCache.removeAllObjects()
        noCoverTracks.removeAll()
        artworkRequestTrackID = nil
        currentArtworkURL = nil
        clearArtworkRetry()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        runningObservers.forEach { workspaceCenter.removeObserver($0) }
        runningObservers.removeAll()
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        if let changeObserver {
            DistributedNotificationCenter.default().removeObserver(changeObserver)
            self.changeObserver = nil
        }
        changeDebounce?.invalidate()
        changeDebounce = nil
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
        refreshPlayerRunning()
        startPolling()
        presentWhenNoTrack = true
        launchPlayerIfNeeded()
        pollNow()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let bundleID = descriptor.bundleID
        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == bundleID
            else { return }
            Task { @MainActor in
                self?.playerIsRunning = true
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
                  app.bundleIdentifier == bundleID
            else { return }
            Task { @MainActor in
                guard let self else { return }
                self.playerIsRunning = false
                self.lastRunningCheck = Date()
                // A read that was in flight when the player quit can still
                // return a track snapshot. Invalidate it before applying the
                // stopped state, or it would overwrite `applyNotRunning`.
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
                self?.refreshPlayerRunning()
                self?.pollNow()
            }
        }
        runningObservers = [launch, terminate, wake]

        if let notification = descriptor.changeNotification {
            changeObserver = DistributedNotificationCenter.default().addObserver(
                forName: notification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleChangeNotification() }
            }
        }
    }

    /// Coalesce the burst the player sends for one change and read once, after
    /// the last notification. The read itself is authoritative; this only
    /// removes the wait until the next scheduled poll.
    private func handleChangeNotification() {
        guard started, !permissionDenied else { return }
        changeDebounce?.invalidate()
        let timer = Timer(timeInterval: changeDebounceInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeDebounce = nil
                self.pollNow()
            }
        }
        // Coalescing the trailing edge with other run-loop work is fine; the
        // burst gap is much larger than this tolerance.
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        changeDebounce = timer
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
            activity: pollActivity,
            availability: availability,
            isRunning: playerIsRunning
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
        activity: PollActivity,
        availability: MusicAvailability,
        isRunning: Bool
    ) -> TimeInterval {
        guard isRunning else { return 30 }
        switch availability {
        case .playing:
            switch activity {
            case .engaged: return 3
            case .background: return 5
            case .probe: return 10
            }
        case .paused:
            switch activity {
            case .engaged: return 5
            case .background: return 10
            case .probe: return 20
            }
        case .noTrack:
            switch activity {
            case .engaged: return 10
            case .background: return 15
            case .probe: return 20
            }
        case .appNotRunning, .permissionDenied:
            return 30
        }
    }

    func setOverlayEngaged(_ engaged: Bool) {
        // Engagement belongs to the active provider only; a probe never speeds
        // up because the other player's record is on screen.
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

    /// Slow the service down to the probe cadence, or return it to the normal
    /// background cadence. Used for the provider auto selection is not showing.
    func setProbeMode(_ probing: Bool) {
        let next: PollActivity = probing ? .probe : .background
        guard next != pollActivity else { return }
        pollActivity = next
        guard started, !permissionDenied else { return }
        scheduleNextPoll()
    }

    /// `runningApplications` materialises every app and asks LaunchServices for
    /// static information; the targeted lookup only resolves one bundle. It is
    /// cached because every poll must not pay for an XPC round trip.
    private func refreshPlayerRunning() {
        playerIsRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: descriptor.bundleID)
            .isEmpty
        lastRunningCheck = Date()
    }

    private func launchPlayerIfNeeded(force: Bool = false) {
        guard force || launchesWhenClosed else { return }
        refreshPlayerRunning()
        guard !playerIsRunning, !launchInFlight else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: descriptor.bundleID) else {
            return
        }
        launchInFlight = true
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.launchInFlight = false
                self.playerIsRunning = true
                self.lastRunningCheck = Date()
                // The workspace launch observer also polls, but the player can
                // take a moment to answer AppleScript. This second read covers
                // the case where the first one arrives too early.
                self.pollNow()
            }
        }
    }

    /// Bring the player forward, launching it when it is closed. The overlay
    /// has nothing to scrub without a track, so the player is where the user
    /// needs to be to start one.
    func presentPlayer() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.bundleID).first {
            app.activate(options: [])
        } else {
            launchPlayerIfNeeded(force: true)
        }
    }

    private func presentForNoTrackIfNeeded() {
        guard presentWhenNoTrack, launchesWhenClosed else { return }
        presentWhenNoTrack = false
        presentPlayer()
    }

    private func applyNoTrack() {
        let changed = availability != .noTrack
        availability = .noTrack
        nowPlaying = nil
        artwork = nil
        currentArtworkURL = nil
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
        if !playerIsRunning {
            // Reconcile at most every 30 s in case the launch notification was
            // missed. When the player is genuinely absent this is the entire tick.
            if Date().timeIntervalSince(lastRunningCheck) >= 30 {
                refreshPlayerRunning()
            }
            guard playerIsRunning else {
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

    private func handle(_ result: Result<PlayerRead, ScriptedBridgeError>) {
        switch result {
        case .failure(let error):
            switch error {
            case .permissionDenied:
                handlePermissionDenied()
            case .notRunning:
                applyNotRunning()
            case .scriptError(let number, let message):
                log.error("Read failed (\(number)): \(message, privacy: .public)")
            }
            return

        case .success(.notRunning):
            applyNotRunning()

        case .success(.noTrack):
            applyNoTrack()

        case .success(.track(let reading)):
            let duration = Double(reading.durationMilliseconds) / 1000
            guard duration > 0.5 else {
                applyNoTrack()
                return
            }

            let trackID = reading.trackID.isEmpty
                ? "\(reading.title)|\(reading.artist)"
                : reading.trackID
            let resolved = resolvedPlaybackState(reportedPlaying: reading.state == "playing")
            let isPlaying = resolved.playing
            let snapshot = NowPlaying(
                trackID: trackID,
                title: reading.title,
                artist: reading.artist,
                album: reading.album,
                duration: duration,
                position: Double(reading.positionMilliseconds) / 1000,
                isPlaying: isPlaying,
                sampledAt: Date()
            )

            let previousTrack = nowPlaying?.trackID
            let previousPlaying = nowPlaying?.isPlaying
            let previousAvailability = availability

            nowPlaying = snapshot
            currentArtworkURL = reading.artworkURL
            if isPlaying {
                availability = .playing
            } else if reading.state == "paused" || resolved.held {
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
                clearArtworkRetry()
                updateArtwork(for: trackID, url: reading.artworkURL)
            } else if artwork == nil {
                // A stop/start cycle clears the cache but keeps the track; make
                // sure the cover is fetched again instead of staying blank.
                updateArtwork(for: trackID, url: reading.artworkURL)
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

    /// Resolve the reported play state against a click that has not been
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
        playerIsRunning = false
        guard availability != .appNotRunning || nowPlaying != nil else { return }
        availability = .appNotRunning
        nowPlaying = nil
        artwork = nil
        currentArtworkURL = nil
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
        log.debug("\(self.descriptor.displayName, privacy: .public) availability: \(name, privacy: .public)")
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
        changeDebounce?.invalidate()
        changeDebounce = nil
        availability = .permissionDenied
        nowPlaying = nil
        artwork = nil
        currentArtworkURL = nil
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
        // The next track's metadata is unknown until the player answers, so
        // read it back as soon as the command completes instead of showing a
        // guess.
        bridge.skip(toNext: forward) { [weak self] in
            self?.pollNow()
        }
    }

    // MARK: - Artwork

    private func updateArtwork(for trackID: String, url: URL?) {
        guard started else { return }
        if pollActivity == .probe {
            // The inactive provider's cover is never on screen, so do not spend
            // network or decode work on it. Drop a stale one so promotion
            // cannot show the previous track's art.
            if nowPlaying?.trackID == trackID, artwork != nil {
                artwork = nil
            }
            return
        }
        if let cached = artworkCache.object(forKey: trackID as NSString) {
            artwork = cached
            return
        }
        if noCoverTracks.contains(trackID) {
            // The player already told us this track has no artwork. Drop the
            // previous cover so the texture falls back to the printed label
            // instead of leaving the old album on screen.
            artwork = nil
            return
        }
        // A request is already running. It will start the request for whichever
        // track is current when it finishes, so a quick double skip cannot
        // leave the second track without its cover.
        guard artworkRequestTrackID == nil else { return }
        if artworkRetryTrackID == trackID,
           let deadline = artworkRetryDeadline,
           Date() < deadline {
            return
        }

        if bridge.providesEmbeddedArtwork {
            requestEmbeddedArtwork(for: trackID)
        } else if let url {
            requestDownloadedArtwork(for: trackID, url: url)
        } else {
            finishArtwork(for: trackID, image: nil, permanentMiss: true)
        }
    }

    private func requestEmbeddedArtwork(for trackID: String) {
        artworkRequestTrackID = trackID
        let generation = lifecycleGeneration
        bridge.readArtworkThumbnail(maxPixelSize: 320) { [weak self] image in
            Task { @MainActor in
                guard let self,
                      self.started,
                      !self.permissionDenied,
                      generation == self.lifecycleGeneration
                else { return }
                self.finishArtwork(for: trackID, image: image, permanentMiss: true)
            }
        }
    }

    private func requestDownloadedArtwork(for trackID: String, url: URL) {
        artworkRequestTrackID = trackID
        let generation = lifecycleGeneration
        ArtworkLoader.load(url: url, maxPixelSize: 320) { [weak self] outcome in
            Task { @MainActor in
                guard let self,
                      self.started,
                      !self.permissionDenied,
                      generation == self.lifecycleGeneration
                else { return }
                switch outcome {
                case .image(let image):
                    self.clearArtworkRetry()
                    self.finishArtwork(for: trackID, image: image, permanentMiss: false)
                case .permanentMiss:
                    self.clearArtworkRetry()
                    self.finishArtwork(for: trackID, image: nil, permanentMiss: true)
                case .transientFailure:
                    self.failArtworkTransiently(for: trackID)
                }
            }
        }
    }

    private func finishArtwork(for trackID: String, image: NSImage?, permanentMiss: Bool) {
        log.debug("artwork finish track=\(trackID, privacy: .public) image=\(image != nil) permanent=\(permanentMiss)")
        // A stop/start cycle can leave an older read in flight; do not clear the
        // marker belonging to a newer request.
        if artworkRequestTrackID == trackID {
            artworkRequestTrackID = nil
        }
        if let image {
            artworkCache.setObject(
                image,
                forKey: trackID as NSString,
                cost: Self.artworkCost(image)
            )
        } else if permanentMiss {
            noCoverTracks.insert(trackID)
        }

        let currentTrackID = nowPlaying?.trackID
        guard currentTrackID == trackID else {
            // The user moved on while this read was in flight. Keep the result
            // for when they come back, and fetch the current track's artwork now.
            if let currentTrackID,
               artworkCache.object(forKey: currentTrackID as NSString) == nil,
               !noCoverTracks.contains(currentTrackID) {
                updateArtwork(for: currentTrackID, url: currentArtworkURL)
                onUpdate?()
            }
            return
        }

        artwork = image
        onUpdate?()
    }

    /// Promotion from probe to active. The cover was deliberately skipped while
    /// the record was not on screen, so fetch it now instead of waiting for the
    /// next poll.
    func resumeArtworkIfNeeded() {
        guard started, pollActivity != .probe, artwork == nil, let now = nowPlaying else { return }
        updateArtwork(for: now.trackID, url: currentArtworkURL)
    }

    /// Keep the previous cover up, but retry this track after a short pause
    /// instead of hammering a down network on every poll.
    private func failArtworkTransiently(for trackID: String) {
        log.debug("artwork transient failure track=\(trackID, privacy: .public)")
        if artworkRequestTrackID == trackID {
            artworkRequestTrackID = nil
        }
        artworkRetryTrackID = trackID
        artworkRetryDeadline = Date().addingTimeInterval(artworkRetryInterval)
        guard nowPlaying?.trackID == trackID else { return }
        artwork = nil
        onUpdate?()
    }

    private func clearArtworkRetry() {
        artworkRetryTrackID = nil
        artworkRetryDeadline = nil
    }

    private static func artworkCost(_ image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }
}
