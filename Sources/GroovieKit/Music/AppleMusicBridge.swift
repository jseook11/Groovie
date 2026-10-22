import AppKit
import Foundation

/// Result of a single read of Music.app.
enum AppleMusicRead: Equatable {
    case notRunning
    case noTrack
    case track(
        state: String,
        positionMilliseconds: Int,
        persistentID: String,
        title: String,
        artist: String,
        album: String,
        durationMilliseconds: Int
    )
}

enum AppleMusicBridgeError: Error, Equatable {
    case permissionDenied
    case notRunning
    case scriptError(Int, String)

    var isPermissionDenied: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// All AppleScript traffic is funnelled through one serial queue. Finishes are
/// coalesced so a slow AppleEvent can never build up a backlog.
final class AppleMusicBridge {
    private let queue = DispatchQueue(label: "com.groovie.applemusic", qos: .userInitiated)

    private var readScript: NSAppleScript?
    private var readScriptFailed = false

    /// Written by callers, read on `queue`. The lock is what actually makes
    /// coalescing work: the newest target replaces any older ones before the
    /// queued pump blocks run.
    private let pendingLock = NSLock()
    private var pendingFinish: (position: Double, wasPlaying: Bool, completion: (() -> Void)?)?
    private var finishInFlight = false

    private static let delimiter = "\u{1F}"

    // MARK: - Reading

    func read(completion: @escaping (Result<AppleMusicRead, AppleMusicBridgeError>) -> Void) {
        queue.async {
            let result = self.performRead()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func performRead() -> Result<AppleMusicRead, AppleMusicBridgeError> {
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

    static func parse(_ text: String) -> Result<AppleMusicRead, AppleMusicBridgeError> {
        if text == "NOTRUNNING" { return .success(.notRunning) }
        if text == "NOTRACK" { return .success(.noTrack) }

        let parts = text.components(separatedBy: delimiter)
        guard parts.count >= 7 else {
            return .failure(.scriptError(-1, "unexpected read result"))
        }
        guard let position = Int(parts[1]),
              let duration = Int(parts[6])
        else {
            return .failure(.scriptError(-1, "unexpected numeric result"))
        }

        return .success(.track(
            state: parts[0],
            positionMilliseconds: position,
            persistentID: parts[2],
            title: parts[3],
            artist: parts[4],
            album: parts[5],
            durationMilliseconds: duration
        ))
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
            let error = Self.bridgeError(from: errorInfo)
            if case .permissionDenied = error {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .groovieMusicPermissionDenied, object: nil)
                }
            }
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
                let error = Self.bridgeError(from: errorInfo)
                if case .permissionDenied = error {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .groovieMusicPermissionDenied, object: nil)
                    }
                }
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
                let error = Self.bridgeError(from: errorInfo)
                if case .permissionDenied = error {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .groovieMusicPermissionDenied, object: nil)
                    }
                }
            }
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    // MARK: - Artwork

    func readArtwork(completion: @escaping (Data?) -> Void) {
        queue.async {
            let data = self.performArtworkRead()
            DispatchQueue.main.async { completion(data) }
        }
    }

    private func performArtworkRead() -> Data? {
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
        return data
    }

    // MARK: - Helpers

    private static func bridgeError(from info: NSDictionary) -> AppleMusicBridgeError {
        let number = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -1
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
        if number == -1743 { return .permissionDenied }
        if number == -600 { return .notRunning }
        return .scriptError(number, message)
    }

    private static let readSource = """
    tell application "Music"
        if it is running then
            set stateText to (player state as string)
            try
                set currentTrackRef to current track
                if currentTrackRef is missing value then return "NOTRACK"
                set trackPersistentID to (persistent ID of currentTrackRef) as text
                set trackName to (name of currentTrackRef) as text
                set trackArtist to (artist of currentTrackRef) as text
                set trackAlbum to (album of currentTrackRef) as text
                set trackDuration to (duration of currentTrackRef) as real
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
    """
}

extension Notification.Name {
    static let groovieMusicPermissionDenied = Notification.Name("groovieMusicPermissionDenied")
}
