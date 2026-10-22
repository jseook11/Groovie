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

    private var pollTimer: Timer?
    private var started = false
    private var readInFlight = false
    private var permissionDenied = false
    private var launchInFlight = false
    /// One-shot: when the first read after starting (or reconnecting) finds no
    /// track, bring Music forward so the user can pick something to play.
    private var presentWhenNoTrack = false

    private var runningObservers: [NSObjectProtocol] = []
    private var permissionObserver: NSObjectProtocol?

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
        permissionDenied = false
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
        pollTimer?.invalidate()
        pollTimer = nil
        readInFlight = false
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
    }

    deinit {
        pollTimer?.invalidate()
    }

    func refresh() {
        permissionDenied = false
        if !started {
            start()
            return
        }
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
            Task { @MainActor in self?.pollNow() }
        }
        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music"
            else { return }
            Task { @MainActor in self?.applyNotRunning() }
        }
        runningObservers = [launch, terminate]
    }

    private func startPolling() {
        guard started, pollTimer == nil else { return }
        // The overlay estimates the playing position locally, so polling only
        // has to notice track/play-state changes. Every AppleScript read costs
        // real CPU, and the previous 0.8 s cadence was the app's idle floor.
        // The block captures the service weakly so the timer cannot keep it
        // alive after teardown.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        // Tolerance keeps the poll from competing with animation frames.
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var isMusicRunning: Bool {
        // `runningApplications` materialises every app and asks LaunchServices
        // for static information; the targeted lookup only resolves one bundle.
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private func launchMusicIfNeeded() {
        guard !isMusicRunning, !launchInFlight else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else {
            return
        }
        launchInFlight = true
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.launchInFlight = false
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
        guard started, !permissionDenied, !readInFlight else { return }
        guard isMusicRunning else {
            applyNotRunning()
            return
        }
        readInFlight = true
        bridge.read { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.readInFlight = false
                self.handle(result)
            }
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
        availability = .permissionDenied
        nowPlaying = nil
        artwork = nil
        clearPendingPlayback()
        pollTimer?.invalidate()
        pollTimer = nil
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

        bridge.readArtworkThumbnail(maxPixelSize: 320) { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
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
