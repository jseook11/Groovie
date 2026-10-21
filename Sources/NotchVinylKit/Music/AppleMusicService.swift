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
        let timer = Timer(timeInterval: 0.8, target: self, selector: #selector(pollTimerFired), userInfo: nil, repeats: true)
        // Tolerance keeps the poll from competing with animation frames.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func pollTimerFired() {
        pollNow()
    }

    private var isMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
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
            let availabilityChanged = availability != .noTrack
            availability = .noTrack
            nowPlaying = nil
            artwork = nil
            if availabilityChanged {
                logAvailabilityIfNeeded()
                onUpdate?()
            }

        case .success(.track(let state, let positionMs, let persistentID, let title, let artist, let album, let durationMs)):
            let duration = Double(durationMs) / 1000
            guard duration > 0.5 else {
                let changed = availability != .noTrack
                availability = .noTrack
                nowPlaying = nil
                if changed { onUpdate?() }
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

    func finishScrub(position: Double, wasPlaying: Bool) {
        if var now = nowPlaying {
            now.position = min(max(position, 0), now.duration)
            now.sampledAt = Date()
            now.isPlaying = wasPlaying
            nowPlaying = now
        }
        bridge.finish(position: position, wasPlaying: wasPlaying) { [weak self] in
            self?.pollNow()
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
