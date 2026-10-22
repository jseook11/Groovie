import AppKit
import Foundation
import ImageIO
import os

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
    /// ImageIO parses and downsamples artwork here, not on the script queue, so
    /// a large cover cannot delay a seek or a transport command.
    private let artworkDecodeQueue = DispatchQueue(label: "com.groovie.artwork", qos: .userInitiated)
    private let log = Logger(subsystem: "com.groovie.app", category: "music")

    /// Covers larger than this are treated as broken rather than materialised
    /// and decoded. Typical embedded artwork is a few megabytes.
    private static let maxArtworkBytes = 32 * 1024 * 1024
    /// Reject pathological dimensions before ImageIO can allocate for them.
    private static let maxArtworkDimension = 20_000
    private static let maxArtworkPixels = 100_000_000

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
                let image = Self.makeArtworkThumbnail(from: data, maxPixelSize: maxPixelSize)
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
        guard data.count <= Self.maxArtworkBytes else {
            log.debug("Skipping artwork: \(data.count, privacy: .public) bytes exceeds the limit")
            return nil
        }
        return data
    }

    private static func makeArtworkThumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // The header is cheap to inspect and catches an image whose dimensions
        // are absurd even when the encoded file is small.
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0,
           height > 0,
           width > Self.maxArtworkDimension
               || height > Self.maxArtworkDimension
               || width * height > Self.maxArtworkPixels {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Decode now while we are on the artwork queue instead of leaving a
            // lazy image for the main thread to decode later.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
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
