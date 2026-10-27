import AppKit
import Foundation

/// Which music player a service drives. The raw value is what the
/// `umak.player` preference persists.
enum PlayerID: String, CaseIterable {
    case music
    case spotify

    /// Proper nouns: not localized, the player calls itself this in every
    /// language.
    var displayName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    /// Whether LaunchServices can resolve the app. A missing player must never
    /// reach AppleScript: compiling `tell application "Spotify"` when Spotify
    /// is absent can fail permanently or ask the user where the app is.
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// The last player the app actually drove. Auto mode uses it to decide which
/// app, if any, may launch on a cold start.
enum PlayerHistory {
    static let lastActiveKey = "umak.player.lastActive"

    static func lastActive(defaults: UserDefaults = .standard) -> PlayerID? {
        guard let raw = defaults.string(forKey: lastActiveKey) else { return nil }
        return PlayerID(rawValue: raw)
    }

    static func recordActive(_ id: PlayerID, defaults: UserDefaults = .standard) {
        defaults.set(id.rawValue, forKey: lastActiveKey)
    }
}

/// The static facts the polling service needs about the player it drives.
struct ScriptedPlayerDescriptor {
    let id: PlayerID
    /// Distributed notification posted on play/pause/track changes. Both
    /// players have one; it is only a hint to read authoritative state, so a
    /// removed or renamed notification degrades to the polling cadence.
    let changeNotification: Notification.Name?

    var displayName: String { id.displayName }
    var bundleID: String { id.bundleID }
}

extension ScriptedPlayerDescriptor {
    static let music = ScriptedPlayerDescriptor(
        id: .music,
        changeNotification: Notification.Name("com.apple.Music.playerInfo")
    )
    /// Spotify does not document this notification in its AppleScript
    /// dictionary, but the desktop app posts it (verified on 1.3.6.1921) with
    /// state, track metadata, duration, and position.
    static let spotify = ScriptedPlayerDescriptor(
        id: .spotify,
        changeNotification: Notification.Name("com.spotify.client.PlaybackStateChanged")
    )
}

/// One authoritative read of a player. Both bridges normalize into this shape
/// so the service's state machine stays player-agnostic.
struct PlayerSnapshot: Equatable {
    /// The player's own vocabulary: "playing", "paused", or "stopped".
    var state: String
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var durationMilliseconds: Int
    var positionMilliseconds: Int
    /// Spotify returns a cover URL; Music embeds the artwork in the script and
    /// leaves this nil.
    var artworkURL: URL?
}

enum PlayerRead: Equatable {
    case notRunning
    case noTrack
    case track(PlayerSnapshot)
}

enum ScriptedBridgeError: Error, Equatable {
    case permissionDenied
    case notRunning
    case scriptError(Int, String)

    var isPermissionDenied: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// Everything the service needs from a player's scripting layer. Commands are
/// fire-and-report; the service polls afterwards for authoritative state.
/// Bridges hop to `ScriptedPlayerQueue` internally; the caller must be on the
/// main actor, where every completion is delivered.
protocol ScriptedPlayerBridge: AnyObject {
    /// Music embeds artwork in the read; Spotify only exposes a URL.
    var providesEmbeddedArtwork: Bool { get }

    func read(completion: @escaping (Result<PlayerRead, ScriptedBridgeError>) -> Void)
    /// Seek to the position the scrub ended on, then restore the play/pause
    /// state from grab time.
    func finish(position: Double, wasPlaying: Bool, completion: (() -> Void)?)
    func togglePlayback(completion: ((Bool) -> Void)?)
    func skip(toNext: Bool, completion: (() -> Void)?)
    /// Embedded-artwork path only (Music). Spotify supplies `artworkURL` in the
    /// read and the service downloads it instead.
    func readArtworkThumbnail(maxPixelSize: Int, completion: @escaping (NSImage?) -> Void)
}

/// AppleScript is process-global and NSAppleScript is not thread-safe: two
/// `executeAndReturnError` calls running at once can deliver one player's reply
/// to the other (a Music answer arriving for a Spotify read, which then fails
/// to parse). Every bridge shares this one serial queue so only one AppleScript
/// runs at a time, however many players are being polled.
enum ScriptedPlayerQueue {
    static let shared = DispatchQueue(label: "com.umak.applescript", qos: .userInitiated)
}

extension Notification.Name {
    /// Posted by either bridge when macOS refuses an Apple Event because the
    /// user has not allowed Automation access for that player.
    static let umakPlayerPermissionDenied = Notification.Name("umakPlayerPermissionDenied")
}
