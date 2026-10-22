import AppKit
import Foundation

/// A tiny stand-in for the real player so the interaction can be demonstrated
/// (and screenshotted) without Apple Music running.
@MainActor
final class DemoMusicService: MusicProviding {
    private struct DemoTrack {
        var title: String
        let artist: String
        let album: String
        let duration: Double
    }

    private(set) var nowPlaying: NowPlaying?
    private(set) var availability: MusicAvailability = .playing
    private(set) var artwork: NSImage?
    var onUpdate: (() -> Void)?

    // A few tracks so skipping can be exercised without Music running.
    private var tracks: [DemoTrack] = [
        DemoTrack(title: "Blue in Green", artist: "Miles Davis", album: "Kind of Blue", duration: 337),
        DemoTrack(title: "So What", artist: "Miles Davis", album: "Kind of Blue", duration: 545),
        DemoTrack(title: "Freddie Freeloader", artist: "Miles Davis", album: "Kind of Blue", duration: 586),
    ]
    private var trackIndex = 0
    private var position: Double = 95

    private var currentDuration: Double { tracks[trackIndex].duration }

    init() {
        // `--long-title` exercises the fixed-width menu header's marquee.
        if ProcessInfo.processInfo.arguments.contains("--long-title") {
            tracks[0].title = "Blue in Green (Remastered 2026 Deluxe Edition)"
        }
        nowPlaying = snapshot(isPlaying: true)
    }

    func start() {}
    func stop() {}
    func presentPlayer() {}
    func refresh() {}

    func estimatedPosition(at date: Date) -> Double {
        guard let now = nowPlaying else { return 0 }
        guard now.isPlaying else { return now.position }
        return min(now.duration, now.position + date.timeIntervalSince(now.sampledAt))
    }

    func finishScrub(position seconds: Double, wasPlaying: Bool) {
        position = min(max(seconds, 0), currentDuration - 0.15)
        nowPlaying?.position = position
        nowPlaying?.sampledAt = Date()
        if nowPlaying?.isPlaying != wasPlaying {
            nowPlaying?.isPlaying = wasPlaying
            nowPlaying?.sampledAt = Date()
        }
        onUpdate?()
    }

    func togglePlayback() {
        guard var now = nowPlaying else { return }
        position = min(max(estimatedPosition(at: Date()), 0), now.duration)
        now.position = position
        now.isPlaying.toggle()
        now.sampledAt = Date()
        nowPlaying = now
        availability = now.isPlaying ? .playing : .paused
        onUpdate?()
    }

    func skipToNext() {
        skip(by: 1)
    }

    func skipToPrevious() {
        skip(by: -1)
    }

    private func skip(by offset: Int) {
        guard let now = nowPlaying else { return }
        trackIndex = (trackIndex + offset + tracks.count) % tracks.count
        position = 0
        nowPlaying = snapshot(isPlaying: now.isPlaying)
        availability = now.isPlaying ? .playing : .paused
        onUpdate?()
    }

    private func snapshot(isPlaying: Bool) -> NowPlaying {
        let track = tracks[trackIndex]
        return NowPlaying(
            trackID: "demo-\(trackIndex)",
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            position: position,
            isPlaying: isPlaying,
            sampledAt: Date()
        )
    }
}
