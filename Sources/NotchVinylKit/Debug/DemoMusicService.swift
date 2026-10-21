import AppKit
import Foundation

/// A tiny stand-in for the real player so the interaction can be demonstrated
/// (and screenshotted) without Apple Music running.
@MainActor
final class DemoMusicService: MusicProviding {
    private(set) var nowPlaying: NowPlaying?
    private(set) var availability: MusicAvailability = .playing
    private(set) var artwork: NSImage?
    var onUpdate: (() -> Void)?

    private var position: Double = 95
    private let duration: Double = 337

    init() {
        nowPlaying = NowPlaying(
            trackID: "demo-kind-of-blue",
            title: "Blue in Green",
            artist: "Miles Davis",
            album: "Kind of Blue",
            duration: duration,
            position: position,
            isPlaying: true,
            sampledAt: Date()
        )
    }

    func start() {}
    func stop() {}
    func refresh() {}

    func estimatedPosition(at date: Date) -> Double {
        guard let now = nowPlaying else { return 0 }
        guard now.isPlaying else { return now.position }
        return min(duration, now.position + date.timeIntervalSince(now.sampledAt))
    }

    func seekLive(to seconds: Double) {
        position = min(max(seconds, 0), duration - 0.15)
        nowPlaying?.position = position
        nowPlaying?.sampledAt = Date()
    }

    func finishScrub(position seconds: Double, wasPlaying: Bool) {
        position = min(max(seconds, 0), duration - 0.15)
        nowPlaying?.position = position
        nowPlaying?.sampledAt = Date()
        nowPlaying?.isPlaying = wasPlaying
        onUpdate?()
    }
}
