import AppKit
import Foundation
import os

/// Reads and drives Spotify.app over AppleScript. Spotify's dictionary differs
/// from Music's in three ways that shape this bridge: `properties of current
/// track` fails (-10000), so the read asks for a property list instead;
/// `player position` is `missing value` when nothing is loaded; and artwork is
/// a URL rather than embedded data, so the service downloads it.
final class SpotifyBridge: ScriptedPlayerBridge {
    let providesEmbeddedArtwork = false

    private let queue = DispatchQueue(label: "com.groovie.spotify.script", qos: .userInitiated)
    private let log = Logger(subsystem: "com.groovie.app", category: "music")

    private var readScript: NSAppleScript?

    /// Written by callers, read on `queue`. The newest finish replaces any
    /// older target before the queued pump blocks run.
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
        if readScript == nil {
            readScript = NSAppleScript(source: Self.readSource)
            // Do not latch a compile failure: a player update or a transient
            // dictionary load problem should heal on the next read.
            guard readScript != nil else {
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

    /// Eight U+001F-separated fields: state, id, name, artist, album, duration
    /// (ms), artwork URL, position (ms). Spotify reports duration in ms in
    /// practice even though its sdef describes seconds.
    static func parse(_ text: String) -> Result<PlayerRead, ScriptedBridgeError> {
        if text == "NOTRUNNING" { return .success(.notRunning) }
        if text == "NOTTRACK" { return .success(.noTrack) }

        let parts = text.components(separatedBy: delimiter)
        guard parts.count >= 8 else {
            return .failure(.scriptError(-1, "unexpected read result"))
        }
        guard let duration = Int(parts[5]),
              let position = Int(parts[7])
        else {
            return .failure(.scriptError(-1, "unexpected numeric result"))
        }

        let trackID = parts[1].isEmpty ? "\(parts[2])|\(parts[3])" : parts[1]
        let artworkURL = parts[6].hasPrefix("https://") || parts[6].hasPrefix("http://")
            ? URL(string: parts[6])
            : nil

        return .success(.track(PlayerSnapshot(
            state: parts[0],
            trackID: trackID,
            title: parts[2],
            artist: parts[3],
            album: parts[4],
            durationMilliseconds: duration,
            positionMilliseconds: position,
            artworkURL: artworkURL
        )))
    }

    // MARK: - Seeking

    /// Seek to the position the scrub ended on, then restore the play/pause
    /// state from grab time. Coalesced: only the newest target survives.
    ///
    /// Spotify sometimes ignores a position change while paused, so a paused
    /// seek resumes playback for the seek and pauses again afterwards. A
    /// playing seek stays a single event.
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
        runPositionScript(finish.position, wasPlaying: finish.wasPlaying) {
            self.finishInFlight = false
            if let completion = finish.completion {
                DispatchQueue.main.async { completion() }
            }
            self.pumpFinish()
        }
    }

    private func runPositionScript(_ seconds: Double, wasPlaying: Bool, completion: @escaping () -> Void) {
        // AppleScript numeric literals always need a dot. `String(format:)`
        // without an explicit locale follows the user's locale and would emit
        // "12,345" on a comma-decimal system.
        let clamped = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            max(0, seconds)
        )
        // When paused, start playback first so the seek lands, then return to
        // the paused state the scrub started from.
        let body: String
        if wasPlaying {
            body = "set player position to \(clamped)"
        } else {
            body = """
            play
            set player position to \(clamped)
            pause
            """
        }
        let source = """
        if application "Spotify" is running then
            with timeout of 5 seconds
                tell application "Spotify"
                    \(body)
                end tell
            end timeout
        end if
        """
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            self.reportPermissionDenied(Self.bridgeError(from: errorInfo))
        }
        completion()
    }

    /// `playpause` is atomic, so it cannot race a state read between deciding
    /// which command to send and sending it.
    func togglePlayback(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let source = """
            if application "Spotify" is running then
                with timeout of 5 seconds
                    tell application "Spotify"
                        playpause
                    end tell
                end timeout
            end if
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

    func skip(toNext: Bool, completion: (() -> Void)? = nil) {
        queue.async {
            // Spotify's `previous track` follows the player's contextual rule:
            // after a few seconds it restarts the current track instead of
            // moving back. Send the same single command its transport button
            // does; forcing a second one can skip two tracks when a previous
            // item does exist, and no AppleScript property exposes the context.
            let command = toNext ? "next track" : "previous track"
            let source = """
            if application "Spotify" is running then
                with timeout of 5 seconds
                    tell application "Spotify"
                        \(command)
                    end tell
                end timeout
            end if
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

    /// Spotify never exposes embedded artwork; the read carries an HTTPS URL
    /// and the service downloads it instead.
    func readArtworkThumbnail(maxPixelSize: Int, completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async { completion(nil) }
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
    if application "Spotify" is running then
        with timeout of 5 seconds
            tell application "Spotify"
                set stateText to (player state as text)
                try
                    -- `properties of current track` fails in Spotify (-10000), but
                    -- a property list is answered in one Apple Event.
                    set trackProperties to {name, artist, album, duration, id, artwork url} of current track
                on error
                    return "NOTTRACK"
                end try
                -- Every coercion is guarded: Spotify uses `missing value` for
                -- fields that do not apply (ads, local files, pauses), and
                -- `missing value as integer` raises -1700. Text coercion of
                -- missing value yields the literal "missing value", so those
                -- are normalized to empty as well.
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                set trackDuration to 0
                set trackID to ""
                set artworkText to ""
                try
                    set trackName to (item 1 of trackProperties) as text
                    if trackName is "missing value" then set trackName to ""
                end try
                try
                    set trackArtist to (item 2 of trackProperties) as text
                    if trackArtist is "missing value" then set trackArtist to ""
                end try
                try
                    set trackAlbum to (item 3 of trackProperties) as text
                    if trackAlbum is "missing value" then set trackAlbum to ""
                end try
                try
                    set trackDuration to (item 4 of trackProperties) as integer
                end try
                try
                    set trackID to (item 5 of trackProperties) as text
                    if trackID is "missing value" then set trackID to ""
                end try
                try
                    set artworkText to (item 6 of trackProperties) as text
                    if artworkText is "missing value" then set artworkText to ""
                end try
                set playerPositionSeconds to 0
                try
                    set playerPositionSeconds to (player position) as real
                end try
                set positionMilliseconds to (playerPositionSeconds * 1000) as integer
                set fieldSeparator to (ASCII character 31)
                return stateText & fieldSeparator & trackID & fieldSeparator & trackName & fieldSeparator & trackArtist & fieldSeparator & trackAlbum & fieldSeparator & (trackDuration as text) & fieldSeparator & artworkText & fieldSeparator & (positionMilliseconds as text)
            end tell
        end timeout
    else
        return "NOTRUNNING"
    end if
    """
}
