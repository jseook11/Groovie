import AppKit
import Foundation

/// A snapshot of what the connected music player is doing.
struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var sampledAt: Date

    var isValid: Bool {
        duration > 1 && !title.isEmpty
    }
}

enum MusicAvailability: Equatable {
    case appNotRunning
    case noTrack
    case paused
    case playing
    case permissionDenied

    var isInteractive: Bool {
        switch self {
        case .paused, .playing: return true
        default: return false
        }
    }
}

/// Abstraction over the player so the interaction can be exercised without Apple Music.
@MainActor
protocol MusicProviding: AnyObject {
    var nowPlaying: NowPlaying? { get }
    var availability: MusicAvailability { get }
    var artwork: NSImage? { get }
    var onUpdate: (() -> Void)? { get set }

    func start()
    func stop()
    /// Bring the player to the front so the user can start playback, launching
    /// it first when it is not running.
    func presentPlayer()
    func estimatedPosition(at date: Date) -> Double
    /// Called once when the record is released. `position` is the target the
    /// scrub ended on and `wasPlaying` is the state at grab time. This is the
    /// only seek in a scrub: issuing one per drag update made Music restart the
    /// track dozens of times a second for no audible benefit.
    func finishScrub(position: Double, wasPlaying: Bool)
    /// Flip between playing and paused without moving the position. Used by a
    /// click on the record's centre label.
    func togglePlayback()
    func refresh()
}

extension MusicProviding {
    func estimatedPosition(at date: Date) -> Double {
        guard let now = nowPlaying else { return 0 }
        guard now.isPlaying else { return now.position }
        let elapsed = date.timeIntervalSince(now.sampledAt)
        return min(now.duration, now.position + max(0, elapsed))
    }
}
