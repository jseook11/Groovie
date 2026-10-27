import AppKit
import Foundation
import os

/// Reads and drives Music.app over AppleScript. The bridge is deliberately
/// tolerant: Music may not be running, may have no track, or access may be
/// denied. Results are normalized into `PlayerRead` so the polling service can
/// stay player-agnostic.
final class AppleMusicBridge: ScriptedPlayerBridge {
    let providesEmbeddedArtwork = true

    private let queue = DispatchQueue(label: "com.groovie.music.script", qos: .userInitiated)
    /// ImageIO parses and downsamples artwork here, not on the script queue, so
    /// a large cover cannot delay a seek or a transport command.
    private let artworkDecodeQueue = DispatchQueue(label: "com.groovie.artwork", qos: .userInitiated)
    private let log = Logger(subsystem: "com.groovie.app", category: "music")

    private var readScript: NSAppleScript?
    private var readScriptFailed = false

    /// Written by callers, read on `queue`. The lock is what actually makes
    /// coalescing work: the newest target replaces any older ones before the
    /// queued pump blocks run.
    private let pendingLock = NSLock()
    private var pendingFinish: (position: Double, wasPlaying: Bool, completion: (() -> Void)?)?
    private var finishInFlight = false

    static let delimiter = "\u{1F}"

    // MARK: - Reading

    func read(completion: @escaping (Result<PlayerRead, ScriptedBridgeError>) -> Void) {
        queue.async {
            let result = self.performRead()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func performRead() -> Result<PlayerRead, ScriptedBridgeError> {
        if readScriptFailed {
            return .failure(.scriptError(-1, "read script unavailable"))
        }
        if readScript == nil {
            readScript = NSAppleScript(source: Self.readSource)
            if readScript == nil {
                readScriptFailed = true
                return .failure(.scriptError(-1, "could not compile read script"))
            }
        }
        guard let script = readScript else {
            return .failure(.scriptError(-1, "no read script"))
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failure(Self.bridgeError(from: errorInfo))
        }
        guard let text = descriptor.stringValue else {
            return .failure(.scriptError(-1, "empty script result"))
        }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> Result<PlayerRead, ScriptedBridgeError> {
        if text == "NOTRUNNING" { return .success(.notRunning) }
        if text == "NOTTRACK" { return .success(.noTrack) }

        let parts = text.components(separatedBy: delimiter)
        guard parts.count >= 7 else {
            return .failure(.scriptError(-1, "unexpected read result"))
        }
        guard let position = Int(parts[1]),
              let duration = Int(parts[6])
        else {
            return .failure(.scriptError(-1, "unexpected numeric result"))
        }

        return .success(.track(PlayerSnapshot(
            state: parts[0],
            trackID: parts[2],
            title: parts[3],
            artist: parts[4],
            album: parts[5],
            durationMilliseconds: duration,
            positionMilliseconds: position,
            artworkURL: nil
        )))
    }

    // MARK: - Seeking

    /// Seek to the position the scrub ended on, then restore the play/pause
    /// state from grab time. Coalesced: only the newest target survives.
    func finish(position: Double, wasPlaying: Bool, completion: (() -> Void)? = nil) {
        pendingLock.lock()
        pendingFinish = (position, wasPlaying, completion)
        pendingLock.unlock()
        queue.async {
            self.pumpFinish()
        }
    }

    private func pumpFinish() {
        pendingLock.lock()
        guard !finishInFlight, let finish = pendingFinish else {
            pendingLock.unlock()
            return
        }
        pendingFinish = nil
        finishInFlight = true
        pendingLock.unlock()
        runPositionScript(finish.position) {
            self.runPlaybackScript(play: finish.wasPlaying) {
                self.finishInFlight = false
                if let completion = finish.completion {
                    DispatchQueue.main.async { completion() }
                }
                self.pumpFinish()
            }
        }
    }

    private func runPositionScript(_ seconds: Double, completion: @escaping () -> Void) {
        let clamped = String(format: "%.3f", max(0, seconds))
        let source = """
        tell application "Music"
            if it is running then
                set player position to \(clamped)
            end if
        end tell
        """
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            self.reportPermissionDenied(Self.bridgeError(from: errorInfo))
        }
        completion()
    }

    private func runPlaybackScript(play: Bool, completion: @escaping () -> Void) {
        let action = play ? "play" : "pause"
        let source = """
        tell application "Music"
            if it is running then
                \(action)
            end if
        end tell
        """
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        completion()
    }

    /// `playpause` is atomic in Music, so it cannot race a state read between
    /// deciding which command to send and sending it.
    func togglePlayback(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let source = """
            tell application "Music"
                if it is running then
                    playpause
                end if
            end tell
            """
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            script?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                self.reportPermissionDenied(Self.bridgeError(from: errorInfo))
            }
            if let completion {
                let succeeded = script != nil && errorInfo == nil
                DispatchQueue.main.async { completion(succeeded) }
            }
        }
    }

    // MARK: - Track changes

    /// Skip to the next or previous track with the same commands Music's
    /// transport buttons use.
    func skip(toNext: Bool, completion: (() -> Void)? = nil) {
        queue.async {
            let command = toNext ? "next track" : "previous track"
            let source = """
            tell application "Music"
                if it is running then
                    \(command)
                end if
            end tell
            """
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            script?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                self.reportPermissionDenied(Self.bridgeError(from: errorInfo))
            }
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    // MARK: - Artwork

    /// Read the current cover and downscale it off the main thread. Embedded
    /// artwork can be several megapixels; decoding it on the main thread was a
    /// measurable part of the skip spike. The AppleScript read stays on the
    /// serial script queue and the decode runs on its own queue.
    func readArtworkThumbnail(maxPixelSize: Int, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            guard let data = self.fetchArtworkData() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.artworkDecodeQueue.async {
                let image = ArtworkThumbnailer.thumbnail(from: data, maxPixelSize: maxPixelSize)
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    private func fetchArtworkData() -> Data? {
        let source = """
        tell application "Music"
            if it is running then
                try
                    set currentTrackRef to current track
                    if (count of artworks of currentTrackRef) > 0 then
                        return raw data of artwork 1 of currentTrackRef
                    end if
                end try
            end if
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        let data = descriptor.data
        guard !data.isEmpty else { return nil }
        guard data.count <= ArtworkThumbnailer.maxArtworkBytes else {
            log.debug("Skipping artwork: \(data.count, privacy: .public) bytes exceeds the limit")
            return nil
        }
        return data
    }

    // MARK: - Helpers

    private static func bridgeError(from info: NSDictionary) -> ScriptedBridgeError {
        let number = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
        if number == -1743 { return .permissionDenied }
        if number == -600 { return .notRunning }
        return .scriptError(number, message)
    }

    private func reportPermissionDenied(_ error: ScriptedBridgeError) {
        guard error.isPermissionDenied else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .grooviePlayerPermissionDenied, object: self)
        }
    }

    private static let readSource = """
    tell application "Music"
        if it is running then
            set stateText to (player state as string)
            try
                -- One Apple Event for every track property instead of six
                -- separate `of current track` reads. The output order below is
                -- unchanged so `parse` stays the same.
                set trackProperties to properties of current track
                set trackPersistentID to (persistent ID of trackProperties) as text
                set trackName to (name of trackProperties) as text
                set trackArtist to (artist of trackProperties) as text
                set trackAlbum to (album of trackProperties) as text
                set trackDuration to (duration of trackProperties) as real
                set playerPositionSeconds to (player position) as real
            on error
                return "NOTTRACK"
            end try
            set positionMilliseconds to (playerPositionSeconds * 1000) as integer
            set durationMilliseconds to (trackDuration * 1000) as integer
            set fieldSeparator to (ASCII character 31)
            return stateText & fieldSeparator & (positionMilliseconds as text) & fieldSeparator & trackPersistentID & fieldSeparator & trackName & fieldSeparator & trackArtist & fieldSeparator & trackAlbum & fieldSeparator & (durationMilliseconds as text)
        else
            return "NOTRUNNING"
        end if
    end tell
    """
}
