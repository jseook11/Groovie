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
    private let log = Logger(subsystem: "com.notchvinyl.app", category: "music")

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

    private var artworkAttempted: Set<String> = []
    private var artworkCache: [String: NSImage] = [:]
    private var artworkRequestInFlight = false
    private var lastLoggedAvailability: MusicAvailability?

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
            forName: .notchVinylMusicPermissionDenied,
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
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        runningObservers.forEach { workspaceCenter.removeObserver($0) }
        runningObservers.removeAll()
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
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
        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(pollTimerFired), userInfo: nil, repeats: true)
        // Tolerance keeps the poll from competing with animation frames.
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func pollTimerFired() {
        pollNow()
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
            let isPlaying = state == "playing"
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
            availability = isPlaying ? .playing : (state == "paused" ? .paused : .noTrack)
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

    private func applyNotRunning() {
        guard availability != .appNotRunning || nowPlaying != nil else { return }
        availability = .appNotRunning
        nowPlaying = nil
        artwork = nil
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
        pollTimer?.invalidate()
        pollTimer = nil
        logAvailabilityIfNeeded()
        onUpdate?()
    }

    // MARK: - Seeking

    func seekLive(to seconds: Double) {
        guard availability.isInteractive else { return }
        bridge.setPosition(seconds)
        if var now = nowPlaying {
            now.position = min(max(seconds, 0), now.duration)
            now.sampledAt = Date()
            nowPlaying = now
        }
    }

    func finishScrub(position: Double?, wasPlaying: Bool) {
        if var now = nowPlaying {
            if let position {
                now.position = min(max(position, 0), now.duration)
                now.sampledAt = Date()
            }
            if now.isPlaying != wasPlaying {
                now.isPlaying = wasPlaying
                now.sampledAt = Date()
            }
            nowPlaying = now
        }
        if let position {
            bridge.finish(position: position, wasPlaying: wasPlaying) { [weak self] in
                self?.pollNow()
            }
        } else {
            // The live seek already landed on the final position. Re-issuing it
            // after the player has advanced would rewind the track, which reads
            // as the scrub being applied twice.
            bridge.setPlaybackState(wasPlaying) { [weak self] in
                self?.pollNow()
            }
        }
    }

    // MARK: - Artwork

    private func updateArtwork(for trackID: String) {
        if let cached = artworkCache[trackID] {
            artwork = cached
            return
        }
        artwork = nil
        guard !artworkAttempted.contains(trackID), !artworkRequestInFlight else { return }
        artworkAttempted.insert(trackID)
        artworkRequestInFlight = true

        bridge.readArtwork { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.artworkRequestInFlight = false
                guard let data,
                      let image = NSImage(data: data),
                      self.nowPlaying?.trackID == trackID
                else { return }
                let scaled = Self.downscaled(image, maxDimension: 320)
                self.artworkCache[trackID] = scaled
                self.artwork = scaled
                self.onUpdate?()
            }
        }
    }

    private static func downscaled(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return image }
        let factor = min(1, maxDimension / max(size.width, size.height))
        guard factor < 0.999 else { return image }
        let target = NSSize(width: size.width * factor, height: size.height * factor)
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        output.unlockFocus()
        return output
    }
}
