import AppKit
import SwiftUI
import os

@MainActor
final class OverlayController {
    let model = VinylViewModel()
    var onPermissionDenied: (() -> Void)?
    var onStateChange: (() -> Void)?

    private(set) var geometry: StageGeometry
    private(set) var layout: VinylLayout
    private var music: MusicProviding

    private var panel: OverlayPanel?
    private var contentView: OverlayContentView?
    private var tickTimer: Timer?
    private var lastTick: CFTimeInterval = CACurrentMediaTime()

    private var session: Session?
    private var scrollSession: ScrollSession?
    private var releaseVelocity: CGFloat = 0
    private var releaseElapsed: Double = 0

    private var snapOpenActive = false
    private var snapOpenVelocity: CGFloat = 0
    private var latched = false
    private var pendingConfirmUntil: TimeInterval?
    private let confirmWindow: TimeInterval = 1.0
    private let scrollConfirmWindow: TimeInterval = 1.4
    private let scrollReconfirmGap: TimeInterval = 0.8
    private let snapOpenStiffness: CGFloat = 320
    private let snapOpenDamping: CGFloat = 26

    private let scrollLog = Logger(subsystem: "com.notchvinyl.app", category: "scroll")
    private let interactionLog = Logger(subsystem: "com.notchvinyl.app", category: "interaction")
    private let scrollPullScale: CGFloat = 0.55
    private let scrollScrubScale: CGFloat = 0.9
    /// Horizontal dead-zone before scroll scrubbing starts. It suppresses the
    /// small sideways jitter produced while scrolling down to open the record.
    private let scrollScrubThreshold: CGFloat = 30
    private let scrollCloseDistance: CGFloat = 40

    private var isEnabled = true
    private var hoverInside = false
    private var hapticTime: TimeInterval = 0
    private var demoTask: Task<Void, Never>?
    private var isDemoActive = false
    private var announcedPermissionDenied = false

    private struct Session {
        var start: CGPoint
        var lastPoint: CGPoint
        var lastTimestamp: TimeInterval
        var pulled = false
        var aborted = false
        var cancelled = false
        var grabbed = false
        var grabbedTrackID = ""
        var wasPlaying = false
        var basePosition: Double = 0
        var duration: Double = 0
        var grabExposure: CGFloat = 0
        var angleAtGrab: Double = 0
        var engine = ScrubEngine()
        var desiredPosition: Double = 0
        var lastSeekAt: TimeInterval = 0
        var lastSeekPosition: Double = -1
        var lastBoundaryHaptic: TimeInterval = 0
        var wiggle = WiggleDetector()
        var dismissAccumulated: CGFloat = 0
        var latchedInteraction = false
        var scrubArmed = false
        var moved = false
        var confirm = ConfirmAccumulator()
    }

    private struct ScrollSession {
        var accumulatedPull: CGFloat = 0
        var grabbed = false
        var didScrub = false
        var wasPlaying = false
        var basePosition: Double = 0
        var duration: Double = 0
        var trackID = ""
        var grabbedExposure: CGFloat = 0
        var angleAtGrab: Double = 0
        var engine = ScrubEngine()
        var virtualX: Double = 0
        var desiredPosition: Double = 0
        var lastSeekAt: TimeInterval = 0
        var lastSeekPosition: Double = -1
        var lastActivity: TimeInterval = 0
        var retract: CGFloat = 0
        var scrubArmed = false
        var confirmTravel: CGFloat = 0
        var confirm = ConfirmAccumulator()
        var wiggle = WiggleDetector()
    }

    init(geometry: StageGeometry, music: MusicProviding) {
        self.geometry = geometry
        self.layout = VinylLayout(geometry: geometry)
        self.music = music
        installPanel()
        music.onUpdate = { [weak self] in self?.syncFromMusic() }
        syncFromMusic()
    }

    // MARK: - Public control

    func activate() {
        isEnabled = true
        model.isEnabled = true
        music.start()
        syncFromMusic()
        panel?.orderFrontRegardless()
    }

    func deactivate() {
        isEnabled = false
        model.isEnabled = false
        vanishImmediately()
        music.stop()
        panel?.orderOut(nil)
    }

    func rebuild(for notch: NotchScreen) {
        vanishImmediately()
        geometry = StageGeometry(notch: notch)
        layout = VinylLayout(geometry: geometry)
        installPanel()
        syncFromMusic()
    }

    func refreshGeometry() {
        guard let notch = NotchScreen.current() else {
            panel?.orderOut(nil)
            return
        }
        rebuild(for: notch)
    }

    /// Re-arm Music polling and, if needed, show the Automation prompt again.
    func refreshMusic() {
        music.refresh()
        syncFromMusic()
    }

    /// Switch the record material and remember the choice for the next launch.
    func selectSkin(_ id: String) {
        let skin = VinylSkin.skin(id: id)
        guard skin.id == id else { return }
        model.skinID = skin.id
        VinylSkin.persist(id: skin.id)
        onStateChange?()
    }

    /// Access for the app delegate's menu state.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// Fresh playback position and duration for the status menu header. Uses
    /// the currently active provider, including the demo provider.
    func playbackSnapshot() -> (position: Double, duration: Double) {
        (
            position: music.estimatedPosition(at: Date()),
            duration: music.nowPlaying?.duration ?? 0
        )
    }

    // MARK: - Panel

    private func installPanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        contentView = nil

        let root = VinylRootView(model: model, layout: layout)
        let hosting = PassthroughHostingView(rootView: root)
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false

        let content = OverlayContentView(hostingView: hosting)
        content.onHoverChanged = { [weak self] inside in
            self?.handleHover(inside)
        }
        content.onMouseDownAt = { [weak self] point, timestamp in
            self?.handleMouseDown(at: point, timestamp: timestamp)
        }
        content.onMouseDraggedTo = { [weak self] point, timestamp in
            self?.handleMouseDragged(to: point, timestamp: timestamp)
        }
        content.onMouseUpAt = { [weak self] point, timestamp in
            self?.handleMouseUp(at: point, timestamp: timestamp)
        }
        content.onScrollWheel = { [weak self] event in
            self?.handleScroll(event)
        }

        let panel = OverlayPanel(frame: geometry.idleFrame)
        panel.contentView = content
        panel.setFrame(geometry.idleFrame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
        self.contentView = content
        model.phase = .idle
        model.exposure = 0
        model.offsetSeconds = 0

        if isEnabled {
            contentView?.window?.invalidateCursorRects(for: content)
        }
    }

    private func showStage() {
        guard let panel else { return }
        if panel.frame != geometry.expandedFrame {
            panel.setFrame(geometry.expandedFrame, display: true)
        }
        startTicking()
    }

    private func hideStage() {
        guard let panel else { return }
        if panel.frame != geometry.idleFrame {
            panel.setFrame(geometry.idleFrame, display: true)
        }
    }

    private func vanishImmediately() {
        stopTicking()
        session = nil
        scrollSession = nil
        releaseElapsed = 0
        releaseVelocity = 0
        snapOpenActive = false
        snapOpenVelocity = 0
        latched = false
        pendingConfirmUntil = nil
        model.confirmProgress = 0
        model.showConfirmGauge = false
        model.phase = .idle
        model.exposure = 0
        model.offsetSeconds = 0
        hideStage()
        NSCursor.arrow.set()
    }

    // MARK: - Music sync

    private func syncFromMusic() {
        let nowPlaying = music.nowPlaying
        model.trackTitle = nowPlaying?.title ?? ""
        model.trackArtist = nowPlaying?.artist ?? ""
        model.isPlaying = nowPlaying?.isPlaying ?? false
        model.artwork = music.artwork
        model.availability = music.availability
        model.permissionDenied = music.availability == .permissionDenied

        if model.permissionDenied, !announcedPermissionDenied {
            announcedPermissionDenied = true
            onPermissionDenied?()
        } else if !model.permissionDenied {
            announcedPermissionDenied = false
        }

        let interactive = music.availability.isInteractive && (nowPlaying?.isValid ?? false)
        model.canInteract = interactive && isEnabled

        if !model.canInteract, model.phase == .armed {
            model.phase = .idle
            NSCursor.arrow.set()
        }

        if model.phase.isEngaged {
            let activeTrackID = session?.grabbedTrackID ?? scrollSession?.trackID
            if let activeTrackID {
                let lostPlayer = music.availability == .permissionDenied
                    || music.availability == .noTrack
                    || music.availability == .appNotRunning
                let trackChanged = (nowPlaying?.trackID).map { $0 != activeTrackID } ?? true
                if lostPlayer || trackChanged {
                    abortActiveGesture()
                }
            }
        }

        onStateChange?()
    }

    // MARK: - Hover

    private func handleHover(_ inside: Bool) {
        hoverInside = inside
        guard session == nil, model.phase == .idle || model.phase == .armed else { return }
        guard isEnabled, model.canInteract else {
            if model.phase == .armed {
                model.phase = .idle
            }
            NSCursor.arrow.set()
            return
        }
        if inside {
            model.phase = .armed
            NSCursor.openHand.set()
        } else if model.phase == .armed {
            model.phase = .idle
            NSCursor.arrow.set()
        }
    }

    // MARK: - Gesture

    private func handleMouseDown(at point: CGPoint, timestamp: TimeInterval) {
        scrollLog.debug("mouseDown at \(point.x, privacy: .public),\(point.y, privacy: .public) phase=\(String(describing: self.model.phase), privacy: .public)")
        if pendingConfirmUntil != nil {
            confirmLatch()
            if model.canInteract, music.nowPlaying != nil {
                beginLatchedMouseInteraction(at: point, timestamp: timestamp)
            } else {
                closeLatched()
            }
            return
        }

        if latched {
            if model.canInteract, music.nowPlaying != nil {
                beginLatchedMouseInteraction(at: point, timestamp: timestamp)
            } else {
                closeLatched()
            }
            return
        }
        // A quick second grab while the record is still collapsing should work.
        if model.phase == .releasing {
            finishCollapse()
        }

        if isEnabled, !model.canInteract, (model.phase == .idle || model.phase == .armed) {
            presentPlayerForUnavailableMusic()
        }

        guard isEnabled,
              model.canInteract,
              model.phase == .idle || model.phase == .armed,
              let now = music.nowPlaying
        else { return }

        var session = Session(start: point, lastPoint: point, lastTimestamp: timestamp)
        session.basePosition = music.estimatedPosition(at: Date())
        session.duration = now.duration
        session.wasPlaying = now.isPlaying
        session.grabbedTrackID = now.trackID
        session.desiredPosition = session.basePosition
        self.session = session

        model.phase = .armed
        startTicking()
    }

    private func handleMouseDragged(to point: CGPoint, timestamp: TimeInterval) {
        if session == nil {
            beginReGrabIfPossible(at: point, timestamp: timestamp)
        }
        guard var session, !session.aborted, !session.cancelled else { return }

        if session.latchedInteraction {
            handleLatchedMouseDrag(&session, point: point, timestamp: timestamp)
            if self.session != nil {
                self.session = session
            }
            return
        }

        let dxTotal = point.x - session.start.x
        let dyTotal = point.y - session.start.y
        let pullDistance = -dyTotal

        if !session.pulled {
            let travel = hypot(dxTotal, dyTotal)
            guard travel >= layout.pullStartDistance else { return }
            guard pullDistance > abs(dxTotal), pullDistance > 0 else {
                session.aborted = true
                self.session = session
                return
            }
            session.pulled = true
            model.phase = .pulling
            model.exposure = layout.exposure(forPullDistance: pullDistance)
            showStage()
            NSCursor.closedHand.set()
        }

        let exposure = layout.exposure(forPullDistance: max(0, pullDistance))

        if !session.grabbed {
            model.exposure = exposure
            if pullDistance >= layout.grabDetent {
                session.grabbed = true
                session.scrubArmed = false
                let extraAtGrab = max(0, pullDistance - layout.grabDetent)
                session.confirm.begin(
                    extra: extraAtGrab,
                    timestamp: timestamp,
                    distance: layout.confirmDistance
                )
                model.confirmProgress = session.confirm.progress
                model.showConfirmGauge = true
                session.grabExposure = layout.fullExposure
                session.angleAtGrab = model.angle
                session.lastPoint = point
                session.engine.begin(
                    x: point.x,
                    timestamp: timestamp,
                    basePosition: session.basePosition,
                    duration: session.duration
                )
                model.phase = .grabbed
                snapOpenActive = true
                snapOpenVelocity = 0
                performHaptic(.alignment)
            }
        }

        if session.grabbed {
            // Continuing downward after the detent fills the confirm gauge. The
            // farther/faster the pull, the more each point counts. When the meter
            // is full, the open state is confirmed (latched).
            let extraPull = max(0, pullDistance - layout.grabDetent)
            if !latched, session.confirm.update(extra: extraPull, timestamp: timestamp) {
                confirmLatch()
            }
            model.confirmProgress = session.confirm.progress
            model.showConfirmGauge = !latched

            // Magnet put-back: a deliberate upward lift puts the record away.
            let verticalDelta = point.y - session.lastPoint.y
            if verticalDelta > 0.01 {
                session.dismissAccumulated += verticalDelta
            } else if verticalDelta < -0.01 {
                session.dismissAccumulated = 0
            }
            if session.dismissAccumulated >= layout.mouseDismissDistance {
                finishMagneticDismiss(session)
                return
            }

            if !session.scrubArmed {
                let deadzone = latched ? CGFloat(4) : layout.confirmScrubDeadzone
                guard abs(point.x - session.start.x) >= deadzone else {
                    session.lastPoint = point
                    self.session = session
                    return
                }
                session.scrubArmed = true
                session.angleAtGrab = model.angle
                session.engine.begin(
                    x: point.x,
                    timestamp: timestamp,
                    basePosition: session.basePosition,
                    duration: session.duration
                )
            }

            let result = session.engine.update(x: point.x, timestamp: timestamp)
            session.desiredPosition = result.position
            model.angle = session.angleAtGrab + result.angleDelta
            model.offsetSeconds = result.delta

            if model.phase == .grabbed, abs(result.angleDelta) > 0.01 {
                model.phase = .scrubbing
            }

            if model.phase == .scrubbing {
                if session.wiggle.update(x: point.x, timestamp: timestamp) {
                    cancelSeekDuringDrag(session)
                    return
                }

                if session.wasPlaying,
                   timestamp - session.lastSeekAt >= 1.0 / 24.0,
                   abs(result.position - session.lastSeekPosition) > 0.012
                {
                    music.seekLive(to: result.position)
                    session.lastSeekAt = timestamp
                    session.lastSeekPosition = result.position
                }

                if result.hitStart || result.hitEnd,
                   timestamp - session.lastBoundaryHaptic > 0.32
                {
                    performHaptic(.alignment)
                    session.lastBoundaryHaptic = timestamp
                }
            }
        }

        session.lastPoint = point
        self.session = session
    }

    /// With no track the gesture cannot do anything. Put Music in front so the
    /// user can start one instead of leaving the overlay silently inert.
    private func presentPlayerForUnavailableMusic() {
        switch model.availability {
        case .appNotRunning, .noTrack:
            music.presentPlayer()
        case .playing, .paused, .permissionDenied:
            break
        }
    }

    /// After a magnetic put-back the mouse button may still be down. Let the
    /// continuing drag start a fresh pull without requiring a new click.
    private func beginReGrabIfPossible(at point: CGPoint, timestamp: TimeInterval) {
        guard session == nil,
              isEnabled,
              model.canInteract,
              model.phase == .idle || model.phase == .armed,
              let now = music.nowPlaying
        else { return }

        var session = Session(start: point, lastPoint: point, lastTimestamp: timestamp)
        session.basePosition = music.estimatedPosition(at: Date())
        session.duration = now.duration
        session.wasPlaying = now.isPlaying
        session.grabbedTrackID = now.trackID
        session.desiredPosition = session.basePosition
        self.session = session
        model.phase = .armed
        startTicking()
    }

    private func handleLatchedMouseDrag(_ session: inout Session, point: CGPoint, timestamp: TimeInterval) {
        if hypot(point.x - session.start.x, point.y - session.start.y) >= 4 {
            session.moved = true
        }
        let vertical = point.y - session.lastPoint.y
        if vertical > 0.01 {
            session.dismissAccumulated += vertical
        } else if vertical < -0.01 {
            session.dismissAccumulated = 0
        }
        if session.dismissAccumulated >= layout.mouseDismissDistance {
            if session.scrubArmed, model.phase == .scrubbing {
                music.finishScrub(position: session.desiredPosition, wasPlaying: session.wasPlaying)
            }
            closeLatched()
            return
        }

        if !session.scrubArmed {
            if abs(point.x - session.start.x) >= 3 {
                session.scrubArmed = true
                session.angleAtGrab = model.angle
                session.engine.begin(
                    x: point.x,
                    timestamp: timestamp,
                    basePosition: session.basePosition,
                    duration: session.duration
                )
            }
        }

        if session.scrubArmed {
            let result = session.engine.update(x: point.x, timestamp: timestamp)
            session.desiredPosition = result.position
            model.angle = session.angleAtGrab + result.angleDelta
            model.offsetSeconds = result.delta

            if model.phase == .grabbed, abs(result.angleDelta) > 0.01 {
                model.phase = .scrubbing
            }
            if model.phase == .scrubbing {
                if session.wiggle.update(x: point.x, timestamp: timestamp) {
                    cancelSeekDuringDrag(session)
                    return
                }
                if session.wasPlaying,
                   timestamp - session.lastSeekAt >= 1.0 / 24.0,
                   abs(result.position - session.lastSeekPosition) > 0.012
                {
                    music.seekLive(to: result.position)
                    session.lastSeekAt = timestamp
                    session.lastSeekPosition = result.position
                }
            }
        }

        session.lastPoint = point
    }

    /// The record stays out after a grab. A new drag scrubs; a plain click or an
    /// upward drag puts it away.
    private func beginLatchedMouseInteraction(at point: CGPoint, timestamp: TimeInterval) {
        guard isEnabled, model.canInteract, let now = music.nowPlaying else { return }
        if let scroll = scrollSession {
            scrollSession = nil
            if scroll.didScrub {
                music.finishScrub(position: scroll.desiredPosition, wasPlaying: scroll.wasPlaying)
            }
        }
        var session = Session(start: point, lastPoint: point, lastTimestamp: timestamp)
        session.pulled = true
        session.grabbed = true
        session.latchedInteraction = true
        session.basePosition = music.estimatedPosition(at: Date())
        session.duration = now.duration
        session.wasPlaying = now.isPlaying
        session.grabbedTrackID = now.trackID
        session.grabExposure = layout.fullExposure
        session.angleAtGrab = model.angle
        session.desiredPosition = session.basePosition
        session.engine.begin(
            x: point.x,
            timestamp: timestamp,
            basePosition: session.basePosition,
            duration: session.duration
        )
        self.session = session
        startTicking()
    }

    /// One deliberate confirmation gesture: a further downward pull, a horizontal
    /// scrub, or a new drag inside the pending window.
    private func confirmLatch() {
        guard !latched else { return }
        latched = true
        pendingConfirmUntil = nil
        model.confirmProgress = 1
        model.showConfirmGauge = false
        interactionLog.debug("confirm -> latched")
        performHaptic(.alignment)
    }

    /// Released after the magnet snap without confirming. Keep the record out for
    /// a moment so a second drag can confirm it; otherwise it falls back in.
    private func enterPendingConfirm() {
        guard !latched else { return }
        pendingConfirmUntil = ProcessInfo.processInfo.systemUptime + confirmWindow
        model.showConfirmGauge = true
        interactionLog.debug("pending confirm window opened")
        model.phase = .grabbed
        model.offsetSeconds = 0
        showStage()
        startTicking()
        NSCursor.openHand.set()
    }

    private func latchRecord() {
        latched = true
        pendingConfirmUntil = nil
        model.confirmProgress = 0
        model.showConfirmGauge = false
        interactionLog.debug("record latched open")
        session = nil
        scrollSession = nil
        model.phase = .grabbed
        model.offsetSeconds = 0
        model.exposure = max(model.exposure, layout.fullExposure - 6)
        showStage()
        startTicking()
        NSCursor.openHand.set()
    }

    private func closeLatched() {
        pendingConfirmUntil = nil
        model.confirmProgress = 0
        model.showConfirmGauge = false
        interactionLog.debug("close latched")
        latched = false
        session = nil
        scrollSession = nil
        snapOpenActive = false
        snapOpenVelocity = 0
        performHaptic(.alignment)
        beginCollapse()
    }

    private func handleMouseUp(at point: CGPoint, timestamp: TimeInterval) {
        if let session, session.latchedInteraction {
            self.session = nil
            if session.scrubArmed {
                if model.phase == .scrubbing {
                    music.finishScrub(position: session.desiredPosition, wasPlaying: session.wasPlaying)
                }
                latchRecord()
            } else if session.moved {
                latchRecord()
            } else {
                closeLatched()
            }
            return
        }
        guard var session else { return }

        // The mouse-up point is used for the final seek; make sure the engine has it.
        if session.grabbed, model.phase == .scrubbing {
            let result = session.engine.update(x: point.x, timestamp: timestamp)
            session.desiredPosition = result.position
            model.angle = session.angleAtGrab + result.angleDelta
            model.offsetSeconds = result.delta
        }

        self.session = nil

        if session.aborted || !session.pulled {
            model.phase = .idle
            stopTicking()
            settleHover()
            return
        }

        if session.grabbed {
            if model.phase == .scrubbing {
                music.finishScrub(position: session.desiredPosition, wasPlaying: session.wasPlaying)
            }
            if latched {
                latchRecord()
            } else {
                enterPendingConfirm()
            }
            return
        }

        // Released before the magnetic detent: fall back into the notch.
        beginCollapse()
    }

    private func beginCollapse() {
        guard model.phase != .releasing else { return }
        latched = false
        pendingConfirmUntil = nil
        model.confirmProgress = 0
        model.showConfirmGauge = false
        model.phase = .releasing
        model.offsetSeconds = 0
        snapOpenActive = false
        snapOpenVelocity = 0
        releaseVelocity = 0
        releaseElapsed = 0
        startTicking()
        NSCursor.arrow.set()
    }

    private func abortActiveGesture() {
        session = nil
        scrollSession = nil
        if model.phase.isEngaged {
            beginCollapse()
        }
    }

    /// Left-right shake during a mouse scrub: discard the seek entirely and put
    /// the player back where it was when the record was grabbed.
    private func cancelSeekDuringDrag(_ session: Session) {
        self.session = nil
        music.finishScrub(position: session.basePosition, wasPlaying: session.wasPlaying)
        performHaptic(.levelChange)
        if latched {
            latchRecord()
        } else {
            beginCollapse()
        }
    }

    // MARK: - Two-finger scroll control

    private func handleScroll(_ event: NSEvent) {
        // Momentum events continue after the fingers lift; they must not keep
        // seeking or extend the session.
        guard event.momentumPhase.isEmpty else { return }
        guard isEnabled, session == nil else { return }
        if !model.canInteract && !latched && pendingConfirmUntil == nil {
            presentPlayerForUnavailableMusic()
            return
        }
        guard scrollSession != nil || latched || pendingConfirmUntil != nil
                || model.phase == .idle || model.phase == .armed || model.phase == .releasing
        else { return }

        let vector = ScrollDirection.physical(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            invertedFromDevice: event.isDirectionInvertedFromDevice,
            precise: event.hasPreciseScrollingDeltas
        )
        guard abs(vector.right) > 0.01 || abs(vector.pull) > 0.01 else { return }
        scrollLog.debug("scroll right=\(vector.right, privacy: .public) pull=\(vector.pull, privacy: .public) inverted=\(event.isDirectionInvertedFromDevice, privacy: .public) precise=\(event.hasPreciseScrollingDeltas, privacy: .public)")

        let timestamp = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime
        let wallClock = ProcessInfo.processInfo.systemUptime

        // A quick downward scroll while the record is still collapsing should
        // start a new session instead of being swallowed by the release.
        if model.phase == .releasing {
            guard vector.pull > 0.5, vector.pull > abs(vector.right) * 1.2 else { return }
            finishCollapse()
        }

        if var scroll = scrollSession {
            let gap = wallClock - scroll.lastActivity
            scroll.lastActivity = wallClock
            scrollSession = scroll
            // A fresh scroll gesture after a pause confirms (latches) the open
            // state. The immediate continuation of the opening scroll does not.
            let closing = vector.pull < -0.5 && abs(vector.pull) >= abs(vector.right) * 1.2
            if !latched, scroll.grabbed, gap > scrollReconfirmGap,
               vector.pull > 0.5, !closing
            {
                confirmLatch()
            }
            processScroll(right: vector.right, pull: vector.pull, timestamp: timestamp, wallClock: wallClock)
            return
        }

        // Pending after a mouse release: any new scroll confirms; scrolling up
        // still closes, and horizontal scroll begins a latched scrub.
        if pendingConfirmUntil != nil, scrollSession == nil {
            if vector.pull < -0.5, abs(vector.pull) >= abs(vector.right) * 1.2 {
                closeLatched()
                return
            }
            guard model.canInteract else { return }
            confirmLatch()
            if abs(vector.right) > 0.2 {
                startLatchedScrollScrub(right: vector.right, timestamp: timestamp, wallClock: wallClock)
            }
            return
        }

        // Latched open: horizontal scroll scrubs, a deliberate vertical scroll up
        // puts the record away. Scrolling down does nothing.
        if latched {
            if vector.pull < -0.5, abs(vector.pull) >= abs(vector.right) * 1.2 {
                closeLatched()
                return
            }
            if abs(vector.right) > 0.2 {
                startLatchedScrollScrub(right: vector.right, timestamp: timestamp, wallClock: wallClock)
            }
            return
        }

        // Opening requires a downward scroll; horizontal or upward gestures in
        // the closed state are ignored.
        guard vector.pull > 0.5,
              vector.pull > abs(vector.right) * 1.2,
              let nowPlaying = music.nowPlaying
        else { return }

        var scroll = ScrollSession()
        scroll.basePosition = music.estimatedPosition(at: Date())
        scroll.duration = nowPlaying.duration
        scroll.wasPlaying = nowPlaying.isPlaying
        scroll.trackID = nowPlaying.trackID
        scroll.desiredPosition = scroll.basePosition
        scroll.lastActivity = wallClock
        scrollSession = scroll

        model.phase = .pulling
        model.exposure = 0
        showStage()
        startTicking()
        NSCursor.closedHand.set()
        performHaptic(.levelChange)

        processScroll(right: 0, pull: vector.pull, timestamp: timestamp, wallClock: wallClock)
    }

    private func processScroll(right: CGFloat, pull: CGFloat, timestamp: TimeInterval, wallClock: TimeInterval) {
        guard var scroll = scrollSession else { return }
        scroll.lastActivity = wallClock

        if !scroll.grabbed {
            if abs(pull) > 0.01 {
                scroll.accumulatedPull = max(0, scroll.accumulatedPull + pull * scrollPullScale)
                let exposure = layout.exposure(forPullDistance: scroll.accumulatedPull)
                model.exposure = exposure

                if scroll.accumulatedPull <= 0.01 {
                    scrollSession = scroll
                    finishScrollSession(commit: false)
                    return
                }

                if scroll.accumulatedPull >= layout.grabDetent {
                    guard let nowPlaying = music.nowPlaying else {
                        scrollSession = scroll
                        finishScrollSession(commit: false)
                        return
                    }
                    scroll.grabbed = true
                    scroll.confirmTravel = 0
                    scroll.confirm.begin(
                        extra: 0,
                        timestamp: timestamp,
                        distance: layout.scrollConfirmDistance
                    )
                    model.confirmProgress = 0
                    model.showConfirmGauge = true
                    scroll.grabbedExposure = layout.fullExposure
                    scroll.basePosition = music.estimatedPosition(at: Date())
                    scroll.duration = nowPlaying.duration
                    scroll.wasPlaying = nowPlaying.isPlaying
                    scroll.trackID = nowPlaying.trackID
                    scroll.desiredPosition = scroll.basePosition
                    scroll.angleAtGrab = model.angle
                    scroll.engine.begin(
                        x: 0,
                        timestamp: timestamp,
                        basePosition: scroll.basePosition,
                        duration: scroll.duration
                    )
                    model.phase = .grabbed
                    snapOpenActive = true
                    snapOpenVelocity = 0
                    performHaptic(.alignment)
                }
            }
            scrollSession = scroll
            return
        }

        // Grabbed: extra downward travel fills the confirm meter. A faster scroll
        // counts each point more heavily.
        if !latched {
            if pull > 0.01 {
                scroll.confirmTravel += pull * scrollPullScale
            } else if pull < -0.01 {
                scroll.confirmTravel = max(0, scroll.confirmTravel - (-pull) * scrollPullScale)
            }
            if scroll.confirm.update(extra: scroll.confirmTravel, timestamp: timestamp) {
                confirmLatch()
            }
        }
        model.confirmProgress = scroll.confirm.progress
        model.showConfirmGauge = !latched

        // Grabbed: only a deliberately vertical reverse scroll puts the record
        // back. Vertical jitter during a horizontal scrub must not close it.
        if pull > 0.01 {
            scroll.retract = max(0, scroll.retract - pull)
        } else if pull < -0.01, abs(pull) >= abs(right) * 1.2 {
            scroll.retract += -pull
            if scroll.retract >= scrollCloseDistance {
                scrollSession = scroll
                finishScrollSession(commit: true)
                return
            }
        } else if abs(right) > 0.01 {
            scroll.retract = max(0, scroll.retract - abs(right) * 0.4)
        }

        if abs(right) > 0.2 {
            scroll.virtualX += Double(right) * Double(scrollScrubScale)
            let x = scroll.virtualX

            // Start scrubbing only after a deliberate horizontal movement. While
            // confirming, the dead-zone is 3x wider so a vertical pull cannot
            // accidentally scrub. Horizontal movement never confirms on its own.
            if !scroll.scrubArmed {
                let deadzone = latched ? scrollScrubThreshold : layout.confirmScrubDeadzone
                if abs(x) >= Double(deadzone) {
                    scroll.scrubArmed = true
                    scroll.virtualX = 0
                    scroll.angleAtGrab = model.angle
                    scroll.engine.begin(
                        x: 0,
                        timestamp: timestamp,
                        basePosition: scroll.basePosition,
                        duration: scroll.duration
                    )
                }
                scrollSession = scroll
                return
            }

            if scroll.wiggle.update(x: x, timestamp: timestamp) {
                scrollSession = scroll
                cancelScrollSession()
                return
            }

            let result = scroll.engine.update(x: x, timestamp: timestamp)
            scroll.desiredPosition = result.position
            model.angle = scroll.angleAtGrab + result.angleDelta
            model.offsetSeconds = result.delta

            if model.phase == .grabbed, abs(result.angleDelta) > 0.01 {
                model.phase = .scrubbing
            }
            if model.phase == .scrubbing {
                scroll.didScrub = true
                if scroll.wasPlaying,
                   timestamp - scroll.lastSeekAt >= 1.0 / 24.0,
                   abs(result.position - scroll.lastSeekPosition) > 0.012
                {
                    music.seekLive(to: result.position)
                    scroll.lastSeekAt = timestamp
                    scroll.lastSeekPosition = result.position
                }
            }
        }

        scrollSession = scroll
    }

    private func startLatchedScrollScrub(right: CGFloat, timestamp: TimeInterval, wallClock: TimeInterval) {
        guard let nowPlaying = music.nowPlaying else { return }
        var scroll = ScrollSession()
        scroll.grabbed = true
        scroll.basePosition = music.estimatedPosition(at: Date())
        scroll.duration = nowPlaying.duration
        scroll.wasPlaying = nowPlaying.isPlaying
        scroll.trackID = nowPlaying.trackID
        scroll.desiredPosition = scroll.basePosition
        scroll.angleAtGrab = model.angle
        scroll.engine.begin(
            x: 0,
            timestamp: timestamp,
            basePosition: scroll.basePosition,
            duration: scroll.duration
        )
        scroll.lastActivity = wallClock
        scrollSession = scroll
        model.phase = .grabbed
        startTicking()
        processScroll(right: right, pull: 0, timestamp: timestamp, wallClock: wallClock)
    }

    private func finishScrollSession(commit: Bool) {
        guard let scroll = scrollSession else { return }
        scrollSession = nil

        if scroll.grabbed, scroll.didScrub {
            let target = commit ? scroll.desiredPosition : scroll.basePosition
            music.finishScrub(position: target, wasPlaying: scroll.wasPlaying)
        }

        if model.phase.isEngaged {
            interactionLog.debug("scroll session closed (commit=\(commit, privacy: .public))")
            performHaptic(.alignment)
            beginCollapse()
        }
    }

    private func latchScrollSession() {
        guard let scroll = scrollSession else { return }
        guard scroll.grabbed else {
            finishScrollSession(commit: false)
            return
        }
        scrollSession = nil
        if scroll.didScrub {
            music.finishScrub(position: scroll.desiredPosition, wasPlaying: scroll.wasPlaying)
        }
        latchRecord()
    }

    private func cancelScrollSession() {
        guard let scroll = scrollSession else { return }
        scrollSession = nil
        if scroll.grabbed, scroll.didScrub {
            music.finishScrub(position: scroll.basePosition, wasPlaying: scroll.wasPlaying)
        }
        performHaptic(.levelChange)
        if latched {
            latchRecord()
        } else if model.phase.isEngaged {
            beginCollapse()
        }
    }

    /// Put the record back while keeping the scrubbed position (not a cancel).
    private func finishMagneticDismiss(_ session: Session) {
        self.session = nil
        if model.phase == .scrubbing {
            music.finishScrub(position: session.desiredPosition, wasPlaying: session.wasPlaying)
        }
        performHaptic(.alignment)
        beginCollapse()
    }

    private func settleHover() {
        // Match the hit test's 1 pt tolerance: pushing the pointer to the top of
        // the screen parks it exactly on the idle frame's top edge.
        let inside = geometry.idleFrame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        if inside, isEnabled, model.canInteract {
            model.phase = .armed
            NSCursor.openHand.set()
        } else {
            model.phase = .idle
            NSCursor.arrow.set()
        }
    }

    // MARK: - Display tick

    private func startTicking() {
        guard tickTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastTick, 0), 0.05)
        lastTick = now

        switch model.phase {
        case .pulling, .grabbed, .releasing:
            if model.isPlaying {
                model.angle = (model.angle + layout.playbackDegreesPerSecond * dt)
                    .truncatingRemainder(dividingBy: 360)
            }
        case .scrubbing, .idle, .armed:
            break
        }

        if snapOpenActive, model.phase == .grabbed || model.phase == .scrubbing {
            stepSnapOpen(dt: dt)
        }

        if model.phase == .releasing {
            stepCollapse(dt: dt)
        }

        // Pending after a mouse release: one more drag must confirm it within
        // the window; otherwise the record falls back into the notch.
        if let deadline = pendingConfirmUntil,
           !latched,
           session == nil,
           scrollSession == nil,
           model.phase == .grabbed || model.phase == .scrubbing,
           ProcessInfo.processInfo.systemUptime > deadline
        {
            pendingConfirmUntil = nil
            interactionLog.debug("pending expired -> close")
            beginCollapse()
        }

        // Scroll gestures have no mouse-up: inactivity is the release. If the
        // record was confirmed it stays out; otherwise it falls back in.
        if let scroll = scrollSession,
           model.phase != .releasing,
           ProcessInfo.processInfo.systemUptime - scroll.lastActivity > scrollConfirmWindow
        {
            if latched {
                latchScrollSession()
            } else {
                finishScrollSession(commit: true)
            }
        }

        // If the mouse-up was lost (space switch, app focus, etc.) finish safely.
        if !isDemoActive, session != nil, model.phase != .releasing, NSEvent.pressedMouseButtons == 0 {
            finishLostDrag()
        }
    }

    private func stepSnapOpen(dt: Double) {
        let dtC = CGFloat(dt)
        let target = layout.fullExposure
        let x = model.exposure
        snapOpenVelocity += (snapOpenStiffness * (target - x) - snapOpenDamping * snapOpenVelocity) * dtC
        var next = x + snapOpenVelocity * dtC
        if next > target + 6 {
            next = target + 6
            snapOpenVelocity = 0
        }
        model.exposure = next
        if abs(target - next) < 0.15, abs(snapOpenVelocity) < 2 {
            model.exposure = target
            snapOpenActive = false
            snapOpenVelocity = 0
        }
    }

    private func stepCollapse(dt: Double) {
        releaseElapsed += dt
        let stiffness = layout.collapseStiffness
        let damping = layout.collapseDamping
        let x = Double(model.exposure)
        releaseVelocity += (-stiffness * x - damping * Double(releaseVelocity)) * dt
        var next = x + Double(releaseVelocity) * dt
        if next < 0 {
            next = 0
            releaseVelocity = 0
        }
        model.exposure = CGFloat(next)

        let settled = abs(next) < 0.25 && abs(releaseVelocity) < 4
        if releaseElapsed >= layout.collapseMaximumTime || settled {
            finishCollapse()
        }
    }

    private func finishCollapse() {
        stopTicking()
        session = nil
        scrollSession = nil
        snapOpenActive = false
        snapOpenVelocity = 0
        latched = false
        pendingConfirmUntil = nil
        model.confirmProgress = 0
        model.showConfirmGauge = false
        model.phase = .idle
        model.exposure = 0
        model.offsetSeconds = 0
        hideStage()
        panel?.orderFrontRegardless()
        contentView?.updateTrackingAreas()
        settleHover()
    }

    private func finishLostDrag() {
        guard let session else { return }
        self.session = nil
        if session.latchedInteraction {
            if session.scrubArmed, model.phase == .scrubbing {
                music.finishScrub(position: session.desiredPosition, wasPlaying: session.wasPlaying)
                latchRecord()
            } else if session.moved {
                latchRecord()
            } else {
                closeLatched()
            }
            return
        }
        if session.grabbed, model.phase == .scrubbing {
            music.finishScrub(position: session.desiredPosition, wasPlaying: session.wasPlaying)
        }
        if session.pulled {
            if session.grabbed {
                latchRecord()
            } else {
                beginCollapse()
            }
        } else {
            model.phase = .idle
            stopTicking()
            settleHover()
        }
    }

    private func performHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - hapticTime > 0.05 else { return }
        hapticTime = now
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // MARK: - Demo

    func runDemo() {
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            await self?.demoSequence()
        }
    }

    private func demoSequence() async {
        guard model.phase == .idle || model.phase == .armed else { return }

        isDemoActive = true
        let demo = DemoMusicService()
        let previous = music
        previous.stop()
        music = demo
        music.onUpdate = { [weak self] in self?.syncFromMusic() }
        music.start()
        syncFromMusic()

        defer {
            isDemoActive = false
            music.stop()
            music = previous
            music.onUpdate = { [weak self] in self?.syncFromMusic() }
            previous.start()
            syncFromMusic()
        }

        func sleep(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        if Task.isCancelled { return }

        await sleep(0.7)
        let notch = geometry.notchRect
        var point = CGPoint(x: notch.midX, y: notch.midY)
        var timestamp = ProcessInfo.processInfo.systemUptime
        handleMouseDown(at: point, timestamp: timestamp)

        // Pull the record out.
        let pullSteps = 36
        for i in 1...pullSteps {
            if Task.isCancelled { return }
            point.y = notch.midY - (110 * CGFloat(i) / CGFloat(pullSteps))
            timestamp += 1.0 / 60.0
            handleMouseDragged(to: point, timestamp: timestamp)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }

        await sleep(0.35)

        // Rewind: drag right.
        let rightSteps = 22
        for _ in 1...rightSteps {
            if Task.isCancelled { return }
            point.x += 120 / CGFloat(rightSteps)
            timestamp += 1.0 / 60.0
            handleMouseDragged(to: point, timestamp: timestamp)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }

        await sleep(0.3)

        // Fast forward: drag left.
        let leftSteps = 18
        for _ in 1...leftSteps {
            if Task.isCancelled { return }
            point.x -= 250 / CGFloat(leftSteps)
            timestamp += 1.0 / 60.0
            handleMouseDragged(to: point, timestamp: timestamp)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }

        await sleep(0.5)

        // Slow, precise forward nudge.
        let slowSteps = 24
        for _ in 1...slowSteps {
            if Task.isCancelled { return }
            point.x -= 26 / CGFloat(slowSteps)
            timestamp += 1.0 / 45.0
            handleMouseDragged(to: point, timestamp: timestamp)
            try? await Task.sleep(nanoseconds: 22_000_000)
        }

        // Hold so the state can be inspected / screenshotted.
        await sleep(4.2)
        if Task.isCancelled { return }
        handleMouseUp(at: point, timestamp: timestamp + 0.05)
        await sleep(0.5)
        if latched { closeLatched() }
    }
}
