import AppKit
import CoreGraphics
import os

/// Owns the desktop decorations, their persistence, and the transient windows
/// used while copying or removing them.
@MainActor
final class DesktopRecordController {
    var onRecordsChanged: (() -> Void)?

    private let store: DesktopRecordStore
    private var skin: VinylSkin
    private var geometry: StageGeometry?
    private var windows: [UUID: DesktopRecordWindow] = [:]
    private var isEnabled = true

    private var draggingID: UUID?
    private var artworkByID: [UUID: NSImage] = [:]
    private var ghostPanel: DesktopCopyGhostPanel?
    private var deletePanel: DesktopDeleteTargetPanel?

    /// Generation counters cancel deferred work when records, the skin, or
    /// visibility change. Restoring and skin refresh are spread across
    /// run-loop turns so a large desktop never blocks the menu bar.
    private var restoreGeneration = 0
    private var skinGeneration = 0
    private var pendingRestorePositions: [UUID: (position: CGPoint, screenID: String?)] = [:]

    private let log = Logger(subsystem: "com.groovie.app", category: "desktop-records")

    init(
        store: DesktopRecordStore? = nil,
        skin: VinylSkin = VinylSkin.skin(id: VinylSkin.launchID)
    ) {
        self.store = store ?? DesktopRecordStore()
        self.skin = skin
    }

    var recordCount: Int { store.records.count }
    var isAtCapacity: Bool { store.records.count >= DesktopRecordGeometry.maxRecords }

    // MARK: - Lifecycle

    func start() {
        scheduleRestore()
    }

    func stop() {
        cancelDeferredWork()
        draggingID = nil
        hideCopyGhost()
        hideDeleteTarget()
        for window in windows.values {
            window.cancelDrag()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        artworkByID.removeAll()
        pendingRestorePositions.removeAll()
        DesktopArtworkRenderer.purge()
        RecordTexture.purge()
    }

    func setActive(_ active: Bool) {
        isEnabled = active
        if active {
            scheduleRestore()
            for window in windows.values {
                window.orderFrontRegardless()
            }
        } else {
            cancelDeferredWork()
            flushRestorePositions()
            // A drag that was interrupted by disabling the feature would
            // otherwise jump back to its last persisted anchor on re-enable.
            persistLivePositions()
            for window in windows.values {
                window.cancelDrag()
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
            artworkByID.removeAll()
            draggingID = nil
            hideCopyGhost()
            hideDeleteTarget()
            // Keep no bitmaps alive while the feature is off. Re-enabling
            // restores incrementally and renders each record once.
            DesktopArtworkRenderer.purge()
            RecordTexture.purge()
        }
    }

    /// Persist the current window origins before tearing the windows down.
    private func persistLivePositions() {
        guard !windows.isEmpty else { return }
        var updates: [(id: UUID, position: CGPoint, screenID: String?)] = []
        for (id, window) in windows {
            let anchor = DesktopRecordGeometry.anchor(
                windowOrigin: window.frame.origin,
                style: window.style,
                recordOut: window.recordOut
            )
            let targetScreen = screen(containing: anchor) ?? NSScreen.main
            updates.append((
                id: id,
                position: anchor,
                screenID: DesktopRecordGeometry.screenID(for: targetScreen)
            ))
        }
        store.updatePositions(updates)
    }

    private func cancelDeferredWork() {
        restoreGeneration += 1
        skinGeneration += 1
    }

    func updateGeometry(_ geometry: StageGeometry?) {
        self.geometry = geometry
        reclampAll()
    }

    func refreshSkins(_ skin: VinylSkin) {
        guard skin != self.skin else { return }
        self.skin = skin
        // Every entry is keyed by the old skin; repainting regenerates what
        // the visible records need.
        DesktopArtworkRenderer.purge()
        RecordTexture.purge()
        skinGeneration += 1
        let generation = skinGeneration
        let pending = store.records.filter { windows[$0.id] != nil }
        refreshSkinStep(pending, index: 0, generation: generation)
    }

    /// Repaint one record per run-loop turn. A skin change misses the render
    /// cache for every record, so a synchronous loop would freeze the menu for
    /// hundreds of milliseconds on a full desktop.
    private func refreshSkinStep(_ pending: [DesktopRecord], index: Int, generation: Int) {
        guard generation == skinGeneration else { return }
        guard index < pending.count else { return }

        let record = pending[index]
        if let window = windows[record.id] {
            let artwork = artworkByID[record.id] ?? store.artwork(for: record)
            if let artwork, artworkByID[record.id] == nil {
                artworkByID[record.id] = artwork
            }
            let image = DesktopArtworkRenderer.image(
                for: record.style,
                recordOut: record.recordOut,
                snapshot: record.track,
                artwork: artwork,
                skin: skin
            )
            window.updateImage(image)
        }

        let next = index + 1
        DispatchQueue.main.async { [weak self] in
            self?.refreshSkinStep(pending, index: next, generation: generation)
        }
    }

    // MARK: - Create

    /// `point == nil` means the packaged-click slot; otherwise the drop point
    /// becomes the new item's anchor (the cover centre for a sleeve, the disc
    /// centre for a disc).
    @discardableResult
    func createRecord(
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        style: DesktopRecordStyle,
        at point: CGPoint?
    ) -> DesktopRecord? {
        guard isEnabled, store.records.count < DesktopRecordGeometry.maxRecords else {
            return nil
        }

        // New items start with a sleeve's record out. `.disc` ignores the flag.
        let recordOut = true
        let targetScreen: NSScreen?
        let position: CGPoint

        if let point {
            targetScreen = screen(containing: point)
            let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            position = DesktopRecordGeometry.clamp(
                anchor: point,
                style: style,
                recordOut: recordOut,
                to: visible
            )
        } else {
            let target = notchScreen() ?? NSScreen.main
            targetScreen = target
            let frame = target?.frame ?? .zero
            let visible = target?.visibleFrame ?? .zero
            let notchHeight = geometry?.notchHeight ?? max(24, frame.maxY - visible.maxY)
            let screenID = DesktopRecordGeometry.screenID(for: target)
            let index = store.records.filter { $0.screenID == screenID }.count
            position = DesktopRecordGeometry.defaultSlot(
                style: style,
                recordOut: recordOut,
                screenFrame: frame,
                visibleFrame: visible,
                notchHeight: notchHeight,
                index: index
            )
        }

        var snapshot = snapshot
        let id = UUID()
        if let artwork, let file = store.writeArtwork(artwork, id: id) {
            snapshot.artworkFile = file
        }

        let record = DesktopRecord(
            id: id,
            track: snapshot,
            style: style,
            position: position,
            screenID: DesktopRecordGeometry.screenID(for: targetScreen),
            recordOut: recordOut
        )

        guard store.insert(record) else {
            log.error("Could not insert desktop record")
            return nil
        }

        addWindow(for: record, artwork: artwork, fadeIn: true)
        onRecordsChanged?()
        return record
    }

    // MARK: - Move / delete

    func beginDrag(_ id: UUID) {
        draggingID = id
    }

    /// Option-click cycles the desktop presentation:
    /// open sleeve -> closed sleeve -> bare disc -> open sleeve.
    /// The anchor — the cover centre for a sleeve, the disc centre for a disc —
    /// stays fixed while the window is rebuilt at the new size.
    func handleClick(id: UUID) {
        toggleRecordState(id: id)
    }

    /// Kept for the `--desktop-demo-toggle` launch flag, which predates the
    /// three-state cycle. New code should call `handleClick(id:)`.
    func toggleStyle(id: UUID) {
        toggleRecordState(id: id)
    }

    private func toggleRecordState(id: UUID) {
        // A click queued before the feature was disabled must not resurrect a
        // hidden window or repopulate the render cache.
        guard isEnabled else { return }
        // A click can follow a sub-4pt press that armed the delete halo. Clear
        // the transient drag UI here as well as in dragEnded, or the "drop to
        // remove" panel can be left behind after the window is rebuilt.
        draggingID = nil
        updateDeleteTarget(visible: false)
        windows[id]?.setDeleteArmed(false)

        guard let record = store.records.first(where: { $0.id == id }) else { return }

        let next = DesktopRecordStyle.next(
            after: record.style,
            recordOut: record.recordOut
        )
        let newStyle = next.style
        let newRecordOut = next.recordOut

        // Prefer the live window origin: it is the freshest position if a drag
        // has not been persisted yet. The persisted `position` is the anchor.
        let anchor: CGPoint
        if let window = windows[id] {
            anchor = DesktopRecordGeometry.anchor(
                windowOrigin: window.frame.origin,
                style: window.style,
                recordOut: window.recordOut
            )
        } else {
            anchor = record.position
        }

        let targetScreen = screen(containing: anchor) ?? NSScreen.main
        let visible = targetScreen?.visibleFrame ?? .zero
        let clampedAnchor = DesktopRecordGeometry.clamp(
            anchor: anchor,
            style: newStyle,
            recordOut: newRecordOut,
            to: visible
        )
        let newScreenID = DesktopRecordGeometry.screenID(for: targetScreen)

        // One document write covers the whole style cycle.
        store.update(
            id: id,
            style: newStyle,
            recordOut: newRecordOut,
            position: clampedAnchor,
            screenID: newScreenID
        )

        var updated = record
        updated.style = newStyle
        updated.recordOut = newRecordOut
        updated.position = clampedAnchor
        updated.screenID = newScreenID

        let artwork = artworkByID[id] ?? store.artwork(for: record)
        if let window = windows.removeValue(forKey: id) {
            window.cancelDrag()
            window.orderOut(nil)
            window.close()
        }
        addWindow(for: updated, artwork: artwork, fadeIn: true)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func dragMoved(_ id: UUID) {
        guard let window = windows[id] else { return }
        let anchor = DesktopRecordGeometry.anchor(
            windowOrigin: window.frame.origin,
            style: window.style,
            recordOut: window.recordOut
        )
        let center = DesktopRecordGeometry.itemCenter(
            anchor: anchor,
            style: window.style,
            recordOut: window.recordOut
        )
        let armed = isInDeleteZone(center)
        window.setDeleteArmed(armed)
        updateDeleteTarget(visible: armed)
    }

    func dragEnded(_ id: UUID, pointer _: CGPoint) {
        draggingID = nil
        updateDeleteTarget(visible: false)
        windows[id]?.setDeleteArmed(false)

        guard let window = windows[id] else {
            return
        }
        let anchor = DesktopRecordGeometry.anchor(
            windowOrigin: window.frame.origin,
            style: window.style,
            recordOut: window.recordOut
        )
        let center = DesktopRecordGeometry.itemCenter(
            anchor: anchor,
            style: window.style,
            recordOut: window.recordOut
        )

        if isInDeleteZone(center) {
            delete(id: id, animated: true)
        } else {
            let targetScreen = screen(containing: center) ?? NSScreen.main
            let visible = targetScreen?.visibleFrame ?? .zero
            let clamped = DesktopRecordGeometry.clamp(
                anchor: anchor,
                style: window.style,
                recordOut: window.recordOut,
                to: visible
            )
            if clamped != anchor {
                window.setFrameOrigin(DesktopRecordGeometry.windowOrigin(
                    anchor: clamped,
                    style: window.style,
                    recordOut: window.recordOut
                ))
            }
            store.updatePosition(
                id: id,
                position: clamped,
                screenID: DesktopRecordGeometry.screenID(for: targetScreen)
            )
        }
    }

    func delete(id: UUID, animated: Bool) {
        guard let window = windows.removeValue(forKey: id) else { return }
        NSCursor.arrow.set()
        artworkByID.removeValue(forKey: id)
        store.remove(id: id)
        // Deleting is rare; dropping the whole composite cache avoids tracking
        // every style/state key a record may have accumulated.
        DesktopArtworkRenderer.purge()
        onRecordsChanged?()

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        if animated {
            // Move the item toward the notch while it fades. If the notch
            // geometry is unavailable, the fade still communicates removal.
            let targetOrigin = deleteZone.map {
                CGPoint(
                    x: $0.midX - window.frame.width / 2,
                    y: $0.midY - window.frame.height / 2
                )
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
                if let targetOrigin {
                    window.animator().setFrameOrigin(targetOrigin)
                }
            } completionHandler: {
                window.orderOut(nil)
                window.close()
            }
        } else {
            window.orderOut(nil)
            window.close()
        }
    }

    func deleteAll() {
        hideCopyGhost()
        hideDeleteTarget()
        draggingID = nil
        for window in windows.values {
            window.cancelDrag()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        artworkByID.removeAll()
        store.removeAll()
        DesktopArtworkRenderer.purge()
        RecordTexture.purge()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onRecordsChanged?()
    }

    // MARK: - Copy ghost

    func showCopyGhost(
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        at point: CGPoint
    ) {
        hideCopyGhost()
        let image = DesktopArtworkRenderer.image(
            for: .disc,
            recordOut: true,
            snapshot: snapshot,
            artwork: artwork,
            skin: skin
        )
        let panel = DesktopCopyGhostPanel(image: image)
        panel.center(on: point)
        panel.orderFrontRegardless()
        ghostPanel = panel
    }

    func moveCopyGhost(to point: CGPoint) {
        ghostPanel?.center(on: point)
    }

    func hideCopyGhost() {
        ghostPanel?.orderOut(nil)
        ghostPanel?.close()
        ghostPanel = nil
    }

    // MARK: - Delete target

    func isInDeleteZone(_ point: CGPoint) -> Bool {
        deleteZone?.contains(point) ?? false
    }

    private var deleteZone: CGRect? {
        if let geometry {
            return DesktopRecordGeometry.deleteZone(
                notchRect: geometry.notchRect,
                screenFrame: geometry.screenFrame
            )
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let notch = CGRect(
            x: screen.frame.midX - 89.5,
            y: screen.frame.maxY - menuBar,
            width: 179,
            height: menuBar
        )
        return DesktopRecordGeometry.deleteZone(notchRect: notch, screenFrame: screen.frame)
    }

    private func updateDeleteTarget(visible: Bool) {
        guard visible, let zone = deleteZone else {
            hideDeleteTarget()
            return
        }
        if let deletePanel {
            if deletePanel.frame != zone {
                deletePanel.setFrame(zone, display: false)
            }
        } else {
            deletePanel = DesktopDeleteTargetPanel(frame: zone)
        }
        deletePanel?.orderFrontRegardless()
    }

    private func hideDeleteTarget() {
        deletePanel?.orderOut(nil)
    }

    // MARK: - Windows

    /// Restore saved items one run-loop turn at a time. Rendering and decoding
    /// artwork for a full desktop can take hundreds of milliseconds; doing it
    /// synchronously would keep the menu-bar item off screen until it finished.
    private func scheduleRestore() {
        guard isEnabled else { return }
        restoreGeneration += 1
        let generation = restoreGeneration
        pendingRestorePositions.removeAll()
        let pending = store.records.filter { windows[$0.id] == nil }
        // Start on the next run-loop turn so app launch can finish first.
        DispatchQueue.main.async { [weak self] in
            self?.restoreStep(pending, index: 0, generation: generation)
        }
    }

    private func restoreStep(_ pending: [DesktopRecord], index: Int, generation: Int) {
        guard generation == restoreGeneration, isEnabled else { return }
        guard index < pending.count else {
            flushRestorePositions()
            return
        }

        let record = pending[index]
        // The record may have been deleted while it waited its turn.
        if windows[record.id] == nil, store.records.contains(where: { $0.id == record.id }) {
            addRestoredWindow(for: record)
        }

        let next = index + 1
        DispatchQueue.main.async { [weak self] in
            self?.restoreStep(pending, index: next, generation: generation)
        }
    }

    private func addRestoredWindow(for record: DesktopRecord) {
        var record = record
        // Geometry is set before restoring now, so clamp here rather than
        // relying on a later reclamp pass that no longer sees these windows.
        if let targetScreen = screen(withID: record.screenID)
            ?? screen(containing: record.position)
            ?? NSScreen.main
        {
            let clamped = DesktopRecordGeometry.clamp(
                anchor: record.position,
                style: record.style,
                recordOut: record.recordOut,
                to: targetScreen.visibleFrame
            )
            let screenID = DesktopRecordGeometry.screenID(for: targetScreen)
            if clamped != record.position || screenID != record.screenID {
                record.position = clamped
                record.screenID = screenID
                pendingRestorePositions[record.id] = (clamped, screenID)
            }
        }
        addWindow(for: record, artwork: store.artwork(for: record))
    }

    /// Persist every clamp found during restore with a single document write.
    private func flushRestorePositions() {
        guard !pendingRestorePositions.isEmpty else { return }
        let updates = pendingRestorePositions.map {
            (id: $0.key, position: $0.value.position, screenID: $0.value.screenID)
        }
        pendingRestorePositions.removeAll()
        store.updatePositions(updates)
    }

    private func addWindow(
        for record: DesktopRecord,
        artwork: NSImage?,
        fadeIn: Bool = false
    ) {
        let image = DesktopArtworkRenderer.image(
            for: record.style,
            recordOut: record.recordOut,
            snapshot: record.track,
            artwork: artwork,
            skin: skin
        )
        let window = DesktopRecordWindow(record: record, image: image)
        window.onDragBegan = { [weak self] id in self?.beginDrag(id) }
        window.onDragMoved = { [weak self] id, _ in self?.dragMoved(id) }
        window.onDragEnded = { [weak self] id, point in self?.dragEnded(id, pointer: point) }
        window.onClicked = { [weak self] id in
            // Let the mouse-up finish before replacing the window.
            DispatchQueue.main.async {
                self?.handleClick(id: id)
            }
        }
        window.setFrameOrigin(DesktopRecordGeometry.windowOrigin(
            anchor: record.position,
            style: record.style,
            recordOut: record.recordOut
        ))
        window.alphaValue = fadeIn ? 0 : 1
        windows[record.id] = window
        if let artwork {
            artworkByID[record.id] = artwork
        }
        if isEnabled {
            window.orderFrontRegardless()
            if fadeIn {
                // A single appearance animation. After this the item is a still
                // image with no timer or ongoing animation.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        }
    }

    private func reclampAll() {
        var updates: [(id: UUID, position: CGPoint, screenID: String?)] = []
        for (id, window) in windows {
            guard let record = store.records.first(where: { $0.id == id }) else { continue }
            guard let targetScreen = screen(withID: record.screenID)
                ?? screen(containing: record.position)
                ?? NSScreen.main
            else { continue }

            let clamped = DesktopRecordGeometry.clamp(
                anchor: record.position,
                style: record.style,
                recordOut: record.recordOut,
                to: targetScreen.visibleFrame
            )
            window.setFrameOrigin(DesktopRecordGeometry.windowOrigin(
                anchor: clamped,
                style: record.style,
                recordOut: record.recordOut
            ))
            let newScreenID = DesktopRecordGeometry.screenID(for: targetScreen)
            if clamped != record.position || newScreenID != record.screenID {
                updates.append((id: id, position: clamped, screenID: newScreenID))
            }
        }
        // One write for the whole display change instead of one per record.
        store.updatePositions(updates)
    }

    // MARK: - Screen helpers

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screen(withID id: String?) -> NSScreen? {
        guard let id else { return nil }
        return NSScreen.screens.first(where: { DesktopRecordGeometry.screenID(for: $0) == id })
    }

    private func notchScreen() -> NSScreen? {
        if let geometry,
           let match = NSScreen.screens.first(where: { $0.frame == geometry.screenFrame })
        {
            return match
        }
        return NotchScreen.current()?.screen ?? NSScreen.main
    }
}

// MARK: - Transient windows

/// A static copy that follows the pointer while the user drags it out of the
/// notch. It never accepts events; the source panel keeps the drag capture.
final class DesktopCopyGhostPanel: NSPanel {
    init(image: NSImage) {
        let size = image.size
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true

        let view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        view.layer?.contentsGravity = .resize
        view.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        view.layer?.magnificationFilter = .linear
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func center(on point: CGPoint) {
        setFrameOrigin(CGPoint(
            x: point.x - frame.width / 2,
            y: point.y - frame.height / 2
        ))
    }
}

/// The soft "drop here to remove" halo shown while a desktop item is dragged
/// over the notch.
final class DesktopDeleteTargetPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        contentView = DesktopDeleteTargetView(
            frame: CGRect(origin: .zero, size: frame.size)
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DesktopDeleteTargetView: NSView {
    private let label = NSTextField(labelWithString: L10n.t(.overlayDropToRemove))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.86)
        label.alignment = .center
        label.frame = CGRect(x: 10, y: 12, width: frameRect.width - 20, height: 16)
        label.autoresizingMask = [.width, .maxYMargin]
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let fill = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 0.55).setFill()
        fill.fill()

        let stroke = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 22,
            yRadius: 22
        )
        stroke.lineWidth = 1
        NSColor(srgbRed: 1, green: 0.62, blue: 0.48, alpha: 0.55).setStroke()
        stroke.stroke()
    }
}
