import AppKit
import Foundation

/// The user's player choice. `auto` follows whichever player is actually
/// playing; the other cases pin one provider and leave the other stopped.
enum PlayerPreference: String, CaseIterable {
    case auto
    case music
    case spotify

    static let defaultsKey = "groovie.player"

    var playerID: PlayerID? {
        switch self {
        case .auto: return nil
        case .music: return .music
        case .spotify: return .spotify
        }
    }

    /// `--player=` overrides the saved choice for one launch without writing
    /// it back, mirroring `--skin=` and `--lang=`.
    static func requested() -> PlayerPreference {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--player=") {
            let raw = String(argument.dropFirst("--player=".count))
            if let preference = PlayerPreference(rawValue: raw) { return preference }
        }
        return stored()
    }

    static func stored(defaults: UserDefaults = .standard) -> PlayerPreference {
        guard let raw = defaults.string(forKey: defaultsKey),
              let preference = PlayerPreference(rawValue: raw)
        else { return .auto }
        return preference
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Pure selection rule, kept static so `--self-test` can exercise the table.
enum PlayerSelection {
    struct Status: Equatable {
        var availability: MusicAvailability
        var lastStartedPlaying: Date?
    }

    /// Pinned modes return that provider. Auto prefers a playing player, then a
    /// paused one, then one that only has a track, then a running one. Ties go
    /// to the most recently started playback, then keep the current provider,
    /// then Music so a cold start is stable.
    static func preferred(
        _ statuses: [PlayerID: Status],
        current: PlayerID?,
        preference: PlayerPreference
    ) -> PlayerID? {
        if let pinned = preference.playerID { return pinned }
        guard !statuses.isEmpty else { return nil }

        let order = PlayerID.allCases
        func score(_ id: PlayerID) -> Int {
            switch statuses[id]?.availability {
            case .playing: return 4
            case .paused: return 3
            case .noTrack: return 2
            // A denied provider is running, and selecting it is what lets the
            // permission alert surface. A closed player has nothing to say.
            case .permissionDenied: return 1
            case .appNotRunning: return 0
            case nil: return 0
            }
        }

        guard let bestScore = order.map(score).max() else { return nil }
        let candidates = order.filter { score($0) == bestScore }
        if candidates.count == 1 { return candidates[0] }

        let dated = candidates.map { id in
            (id, statuses[id]?.lastStartedPlaying ?? .distantPast)
        }
        if let newest = dated.max(by: { $0.1 < $1.1 }), newest.1 > .distantPast {
            // Only a strictly newer playback start wins a tie; two providers
            // that have both been playing since launch keep the current one.
            let newestDate = newest.1
            let tied = dated.filter { $0.1 == newestDate }
            if tied.count == 1 { return newest.0 }
        }
        if let current, candidates.contains(current) { return current }
        return candidates.first
    }
}

/// The single provider the app injects. It owns one service per player, applies
/// the preference, and forwards the front of `MusicProviding` to whichever
/// service is active so the rest of the app never has to know.
@MainActor
final class PlayerCoordinator: MusicProviding {
    private(set) var preference: PlayerPreference
    private let services: [PlayerID: ScriptedMusicService]
    private var activeID: PlayerID
    private var statuses: [PlayerID: PlayerSelection.Status] = [:]
    private var wasPlaying: [PlayerID: Bool] = [:]
    private var lastAvailability: [PlayerID: MusicAvailability] = [:]
    private var stageEngaged = false
    private var running = false

    var onUpdate: (() -> Void)?

    var nowPlaying: NowPlaying? { activeService.nowPlaying }
    var availability: MusicAvailability { activeService.availability }
    var artwork: NSImage? { activeService.artwork }

    /// Used by the menu header and the permission alert, which name the player
    /// the user is actually controlling.
    var activePlayerName: String { activeID.displayName }

    private var activeService: ScriptedMusicService {
        // Every PlayerID has a service, so this cannot be nil.
        services[activeID]!
    }

    init(preference: PlayerPreference = .requested()) {
        self.preference = preference
        let music = ScriptedMusicService(descriptor: .music, bridge: AppleMusicBridge())
        let spotify = ScriptedMusicService(descriptor: .spotify, bridge: SpotifyBridge())
        self.services = [.music: music, .spotify: spotify]
        self.activeID = preference.playerID ?? .music
        for (id, service) in services {
            statuses[id] = PlayerSelection.Status(
                availability: service.availability,
                lastStartedPlaying: nil
            )
            service.onUpdate = { [weak self] in
                self?.serviceDidUpdate(id)
            }
        }
    }

    // MARK: - MusicProviding

    func start() {
        running = true
        switch preference {
        case .auto:
            startBoth()
        case .music, .spotify:
            startPinned()
        }
        onUpdate?()
    }

    func stop() {
        running = false
        services.values.forEach { $0.stop() }
    }

    func refresh() {
        guard running else { return }
        switch preference {
        case .auto:
            services.values.forEach { $0.refresh() }
        case .music, .spotify:
            if let id = preference.playerID { services[id]?.refresh() }
        }
        onUpdate?()
    }

    func setOverlayEngaged(_ engaged: Bool) {
        stageEngaged = engaged
        activeService.setOverlayEngaged(engaged)
    }

    func presentPlayer() {
        activeService.presentPlayer()
    }

    func estimatedPosition(at date: Date) -> Double {
        activeService.estimatedPosition(at: date)
    }

    func finishScrub(position: Double, wasPlaying: Bool) {
        activeService.finishScrub(position: position, wasPlaying: wasPlaying)
    }

    func togglePlayback() {
        activeService.togglePlayback()
    }

    func skipToNext() {
        activeService.skipToNext()
    }

    func skipToPrevious() {
        activeService.skipToPrevious()
    }

    // MARK: - Preference

    func setPreference(_ newPreference: PlayerPreference) {
        guard newPreference != preference else { return }
        preference = newPreference
        newPreference.persist()
        // A preference change while the overlay is off only records the
        // choice; the next start honours it. Starting services here would
        // re-arm polling and could launch a player behind a disabled overlay.
        guard running else {
            onUpdate?()
            return
        }
        switch newPreference {
        case .auto:
            startBoth()
        case .music, .spotify:
            startPinned()
        }
        onUpdate?()
    }

    // MARK: - Lifecycle

    private func startBoth() {
        services.values.forEach { $0.stop() }
        wasPlaying.removeAll()
        statuses.removeAll()
        lastAvailability.removeAll()

        // Only one provider may open its app during startup: the one that is
        // already running, or Music when neither is. Launching both would
        // surprise a user who only installed the other player.
        let runningIDs = PlayerID.allCases.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
        let startup: PlayerID
        if runningIDs.count == 1, let only = runningIDs.first {
            startup = only
        } else if runningIDs.isEmpty {
            startup = .music
        } else {
            startup = activeID
        }

        for id in PlayerID.allCases {
            let service = services[id]!
            service.launchesWhenClosed = (id == startup)
            statuses[id] = PlayerSelection.Status(
                availability: service.availability,
                lastStartedPlaying: nil
            )
            service.start()
        }

        let next = PlayerSelection.preferred(statuses, current: activeID, preference: .auto)
        if let next {
            activate(next)
        } else {
            activate(.music)
        }
    }

    private func startPinned() {
        guard let pinned = preference.playerID else { return }
        services.values.forEach { $0.stop() }
        wasPlaying.removeAll()
        for id in PlayerID.allCases {
            statuses[id] = PlayerSelection.Status(
                availability: services[id]!.availability,
                lastStartedPlaying: nil
            )
        }
        let service = services[pinned]!
        service.launchesWhenClosed = true
        activeID = pinned
        service.start()
        service.setProbeMode(false)
        service.setOverlayEngaged(stageEngaged)
    }

    /// Move the front of the app to `id`. The previous active provider stays
    /// running in auto mode, but only at the probe cadence.
    private func activate(_ id: PlayerID) {
        let changed = id != activeID
        activeID = id
        for playerID in PlayerID.allCases where playerID != id {
            if preference == .auto {
                services[playerID]?.launchesWhenClosed = false
                services[playerID]?.setProbeMode(true)
            }
        }
        let service = services[id]!
        service.launchesWhenClosed = true
        service.setProbeMode(false)
        service.setOverlayEngaged(stageEngaged)
        service.resumeArtworkIfNeeded()
        statuses[id] = PlayerSelection.Status(
            availability: service.availability,
            lastStartedPlaying: statuses[id]?.lastStartedPlaying
        )
        if changed {
            onUpdate?()
        }
    }

    // MARK: - Updates

    private func serviceDidUpdate(_ id: PlayerID) {
        let previousAvailability = lastAvailability[id]
        updateStatus(for: id)
        lastAvailability[id] = services[id]?.availability

        // The player driving the record just left playback. Check the other
        // provider now instead of waiting out its probe interval, so takeover
        // is a round trip rather than up to 20 seconds.
        if preference == .auto,
           id == activeID,
           previousAvailability == .playing,
           services[id]?.availability != .playing {
            for playerID in PlayerID.allCases where playerID != id {
                services[playerID]?.pollNow()
            }
        }

        if preference == .auto,
           let next = PlayerSelection.preferred(statuses, current: activeID, preference: .auto),
           next != activeID {
            activate(next)
            return
        }
        if id == activeID {
            onUpdate?()
        }
    }

    private func updateStatus(for id: PlayerID) {
        let service = services[id]!
        let playing = service.availability == .playing
        var status = statuses[id]
            ?? PlayerSelection.Status(availability: service.availability, lastStartedPlaying: nil)
        status.availability = service.availability
        if playing, wasPlaying[id] != true {
            status.lastStartedPlaying = Date()
        }
        wasPlaying[id] = playing
        statuses[id] = status
    }
}
