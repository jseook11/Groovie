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
    /// paused one, then one that only has a track; denied and closed players
    /// tie for last. A playing tie goes to the most recent playback start,
    /// then keeps the current provider, then Music so a cold start is stable.
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
            // A denied provider cannot be driven. It is only worth selecting
            // when it is the player already on screen, where the permission
            // alert can explain the state; a denied probe must never take over
            // a working or current player. Explicitly pinning it still starts
            // it, so the alert can surface on request.
            case .permissionDenied: return 0
            case .appNotRunning: return 0
            case nil: return 0
            }
        }

        guard let bestScore = order.map(score).max() else { return nil }
        let candidates = order.filter { score($0) == bestScore }
        if candidates.count == 1 { return candidates[0] }

        // Only a playing tie is decided by playback recency. A denied or
        // closed provider can still carry an old `lastStartedPlaying` from
        // before it stopped, and that must not let it displace a current or
        // closed player on an otherwise meaningless tie.
        if bestScore == 4 {
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
        }
        if let current, candidates.contains(current) { return current }
        return candidates.first
    }
}

/// Pure cold-start rule, kept static so `--self-test` can verify which app, if
/// any, auto mode may open. A running player is used as-is; otherwise the last
/// player the user actually drove is reopened. No history means no launch.
enum PlayerLaunchPolicy {
    static func startupPlayer(
        active: PlayerID,
        lastActive: PlayerID?,
        installed: Set<PlayerID>,
        running: Set<PlayerID>
    ) -> PlayerID? {
        let runningInstalled = running.intersection(installed)
        if runningInstalled.count == 1 {
            return runningInstalled.first
        }
        if runningInstalled.count > 1 {
            // `active` is the synthetic Music default on a true cold start.
            // The last player the user actually drove is the better tie-break.
            return [lastActive, active, runningInstalled.first]
                .compactMap { $0 }
                .first { runningInstalled.contains($0) }
        }
        guard let lastActive, installed.contains(lastActive) else { return nil }
        return lastActive
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
    private var installedIDs: Set<PlayerID> = []
    private var startedIDs: Set<PlayerID> = []
    /// Avoids rewriting defaults on every poll for the same active player.
    private var lastRecordedActiveID: PlayerID?
    private var stageEngaged = false
    /// A takeover became preferable while the record was out. Applying it
    /// mid-gesture would swap the player under the user's hand and send
    /// `finishScrub` to the wrong service, so it waits for disengagement.
    private var pendingSelection = false
    /// The installed set changed while the record was out; rebuilding services
    /// would restart the active one mid-gesture.
    private var pendingRestart = false
    /// Service callbacks can fire synchronously from `start()`. Selection is
    /// suspended until every status has been seeded.
    private var initializing = false
    private var running = false
    private var playerAppObserver: NSObjectProtocol?

    var onUpdate: (() -> Void)?

    var nowPlaying: NowPlaying? { activeService.nowPlaying }
    var availability: MusicAvailability { activeService.availability }
    var artwork: NSImage? { activeService.artwork }

    /// Used by the menu header and the permission alert, which name the player
    /// the user is actually controlling.
    var activePlayerID: PlayerID { activeID }
    var activePlayerName: String { activeID.displayName }
    var activePlayerIsInstalled: Bool { activeID.isInstalled }
    var playerIdentity: String? { activeID.rawValue }

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
        self.lastRecordedActiveID = PlayerHistory.lastActive()
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
        // The controller calls `start()` again when the screen configuration
        // changes. Restarting the services there would re-run the cold-start
        // launch policy and could reopen a player behind the user's back.
        if running {
            activeService.setOverlayEngaged(stageEngaged)
            onUpdate?()
            return
        }
        running = true
        observePlayerApps()
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
        startedIDs.removeAll()
        pendingSelection = false
        pendingRestart = false
        initializing = false
        stageEngaged = false
        if let playerAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(playerAppObserver)
            self.playerAppObserver = nil
        }
        services.values.forEach { $0.stop() }
    }

    /// A player installed after launch (or launched for the first time) was not
    /// in the startup candidate set. Pick it up without requiring a manual
    /// Reconnect.
    private func observePlayerApps() {
        guard playerAppObserver == nil else { return }
        playerAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = PlayerID.allCases.first(where: { $0.bundleID == app.bundleIdentifier })
            else { return }
            Task { @MainActor in
                guard let self, self.running, !self.startedIDs.contains(id) else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard running else { return }
        let installed = Set(PlayerID.allCases.filter { $0.isInstalled })
        // Rebuilding services while the record is out would restart the active
        // provider mid-gesture. Record the need and rebuild on disengage.
        if stageEngaged, installed != installedIDs {
            pendingRestart = true
            onUpdate?()
            return
        }
        switch preference {
        case .auto:
            // An app installed or removed while the menu was open changes the
            // candidate set; rebuild services instead of polling a player the
            // coordinator was never told about.
            if installed != installedIDs {
                startBoth()
            } else {
                installed.forEach { services[$0]?.refresh() }
            }
        case .music, .spotify:
            guard let id = preference.playerID else { break }
            installedIDs = installed
            if installed.contains(id) {
                if startedIDs.contains(id) {
                    services[id]?.refresh()
                } else {
                    startPinned()
                }
            } else {
                // The pinned player is missing: leave it selected so the menu
                // and header keep naming it, but stop all scripting work.
                services.values.forEach { $0.stop() }
                startedIDs.removeAll()
            }
        }
        onUpdate?()
    }

    func setOverlayEngaged(_ engaged: Bool) {
        stageEngaged = engaged
        activeService.setOverlayEngaged(engaged)
        guard !engaged else { return }
        if pendingRestart {
            pendingRestart = false
            refresh()
            return
        }
        guard pendingSelection else { return }
        pendingSelection = false
        if preference == .auto,
           let next = PlayerSelection.preferred(
               eligibleStatuses,
               current: activeID,
               preference: .auto
           ),
           next != activeID {
            activate(next)
        }
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
            // Keep the menu titles honest about the player the user just
            // pinned, even though no service is running yet.
            if let id = newPreference.playerID {
                activeID = id
            }
            pendingSelection = false
            pendingRestart = false
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
        initializing = true
        services.values.forEach { $0.stop() }
        startedIDs.removeAll()
        wasPlaying.removeAll()
        statuses.removeAll()
        lastAvailability.removeAll()
        pendingSelection = false

        let installed = Set(PlayerID.allCases.filter { $0.isInstalled })
        installedIDs = installed
        let running = Set(installed.filter { $0.isRunning })

        // Launch at most one app on a cold start, and only when the choice is
        // meaningful. An already-running player is used as-is; otherwise the
        // last player the user actually drove may be reopened. With no history
        // Auto opens nothing, so a Spotify user is not handed Music.
        let startup = PlayerLaunchPolicy.startupPlayer(
            active: activeID,
            lastActive: PlayerHistory.lastActive(),
            installed: installed,
            running: running
        )
        // Start from the player we just chose to use or launch. Without this,
        // an equal-score cold start keeps Music selected even when Spotify is
        // the only running app, flashing the wrong name until the first poll.
        if let startup {
            activeID = startup
        }

        for id in PlayerID.allCases where installed.contains(id) {
            let service = services[id]!
            service.launchesWhenClosed = (id == startup)
            statuses[id] = PlayerSelection.Status(
                availability: service.availability,
                lastStartedPlaying: nil
            )
            service.start()
        }
        startedIDs = installed
        initializing = false

        let next = PlayerSelection.preferred(
            eligibleStatuses,
            current: activeID,
            preference: .auto
        )
        let fallback: PlayerID
        if installed.contains(activeID) {
            fallback = activeID
        } else {
            fallback = PlayerID.allCases.first { installed.contains($0) } ?? .music
        }
        activate(next ?? fallback)
    }

    private func startPinned() {
        guard let pinned = preference.playerID else { return }
        initializing = true
        services.values.forEach { $0.stop() }
        startedIDs.removeAll()
        wasPlaying.removeAll()
        lastAvailability.removeAll()
        pendingSelection = false

        let installed = Set(PlayerID.allCases.filter { $0.isInstalled })
        installedIDs = installed
        activeID = pinned

        for id in PlayerID.allCases {
            statuses[id] = PlayerSelection.Status(
                availability: services[id]!.availability,
                lastStartedPlaying: nil
            )
        }

        guard installed.contains(pinned) else {
            initializing = false
            return
        }
        let service = services[pinned]!
        service.launchesWhenClosed = true
        service.start()
        startedIDs = [pinned]
        initializing = false
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
        service.launchesWhenClosed = installedIDs.contains(id)
        service.setProbeMode(false)
        service.setOverlayEngaged(stageEngaged)
        service.resumeArtworkIfNeeded()
        statuses[id] = PlayerSelection.Status(
            availability: service.availability,
            lastStartedPlaying: statuses[id]?.lastStartedPlaying
        )
        if installedIDs.contains(id),
           service.availability != .appNotRunning,
           service.availability != .permissionDenied {
            recordActiveIfNeeded(id)
        }
        if changed {
            onUpdate?()
        }
    }

    private var eligibleStatuses: [PlayerID: PlayerSelection.Status] {
        statuses.filter { installedIDs.contains($0.key) }
    }

    private func recordActiveIfNeeded(_ id: PlayerID) {
        guard lastRecordedActiveID != id else { return }
        lastRecordedActiveID = id
        PlayerHistory.recordActive(id)
    }

    // MARK: - Updates

    private func serviceDidUpdate(_ id: PlayerID) {
        let previousAvailability = lastAvailability[id]
        updateStatus(for: id)
        lastAvailability[id] = services[id]?.availability
        // `start()` reads providers synchronously, and those callbacks must
        // not select against a half-seeded status table.
        guard !initializing else { return }

        // Let the UI and the permission alert observe a denial before any
        // takeover decision moves the record to another player.
        if id == activeID, services[id]?.availability == .permissionDenied {
            onUpdate?()
            // The other provider may already be playing but will not emit a
            // new update on its own. Poll it now and reconsider after the
            // alert has had a chance to run, instead of stranding the record
            // on a player that cannot be controlled.
            for playerID in PlayerID.allCases where playerID != id && installedIDs.contains(playerID) {
                services[playerID]?.pollNow()
            }
            DispatchQueue.main.async { [weak self] in
                self?.reconsiderSelection()
            }
            return
        }

        if id == activeID,
           installedIDs.contains(id),
           let availability = services[id]?.availability,
           availability == .playing || availability == .paused || availability == .noTrack {
            recordActiveIfNeeded(id)
        }

        // The player driving the record just left playback. Check the other
        // provider now instead of waiting out its probe interval, so takeover
        // is a round trip rather than up to 30 seconds.
        if preference == .auto,
           id == activeID,
           previousAvailability == .playing,
           services[id]?.availability != .playing {
            for playerID in PlayerID.allCases where playerID != id {
                if installedIDs.contains(playerID) {
                    services[playerID]?.pollNow()
                }
            }
        }

        if preference == .auto,
           let next = PlayerSelection.preferred(
               eligibleStatuses,
               current: activeID,
               preference: .auto
           ),
           next != activeID {
            if stageEngaged {
                // Swapping mid-gesture would change what the record is
                // scrubbing and could send finishScrub to the wrong service.
                pendingSelection = true
                if id == activeID { onUpdate?() }
            } else {
                activate(next)
            }
            return
        }
        if id == activeID {
            onUpdate?()
        }
    }

    /// Re-evaluate auto selection outside a service callback. Used after a
    /// permission alert and when the record returns from a deferred switch.
    private func reconsiderSelection() {
        guard running, !initializing, preference == .auto else { return }
        guard let next = PlayerSelection.preferred(
            eligibleStatuses,
            current: activeID,
            preference: .auto
        ), next != activeID else { return }
        if stageEngaged {
            pendingSelection = true
        } else {
            activate(next)
        }
    }

    private func updateStatus(for id: PlayerID) {
        let service = services[id]!
        let playing = service.availability == .playing
        var status = statuses[id]
            ?? PlayerSelection.Status(availability: service.availability, lastStartedPlaying: nil)
        status.availability = service.availability
        // The first observation only tells us the player is playing, not when
        // it started. Stamping it would let whichever read finishes last win a
        // two-player playing tie. Only a real paused/stopped -> playing
        // transition gets a timestamp.
        if playing, wasPlaying[id] == false {
            status.lastStartedPlaying = Date()
        }
        wasPlaying[id] = playing
        statuses[id] = status
    }
}
