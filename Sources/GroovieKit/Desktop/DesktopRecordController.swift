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

    private var pointerMonitor: Any?
    private var optionTimer: Timer?
    private var draggingID: UUID?
    private var ghostPanel: DesktopCopyGhostPanel?
    private var deletePanel: DesktopDeleteTargetPanel?

    private let log = Logger(subsystem: "com.groovie.app", category: "desktop-records")

    init(
        store: DesktopRecordStore? = nil,
        skin: VinylSkin = VinylSkin.skin(id: VinylSkin.launchID)
    ) {
        self.store = store ?? DesktopRecordStore()
        self.skin = skin
    }

    var recordCount: Int { store.records.count }
    var records: [DesktopRecord] { store.records }
    var isAtCapacity: Bool { store.records.count >= DesktopRecordGeometry.maxRecords }

    // MARK: - Lifecycle

    func start() {
        restoreWindows()
        installPointerMonitor()
    }

    func stop() {
        removePointerMonitor()
        stopOptionTimer()
        hideCopyGhost()
        hideDeleteTarget()
        for window in windows.values {
            window.cancelDrag()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    func setActive(_ active: Bool) {
        isEnabled = active
        if active {
            restoreWindows()
            for window in windows.values {
                window.orderFrontRegardless()
            }
            installPointerMonitor()
            pollOptionState()
        } else {
            for window in windows.values {
                window.cancelDrag()
                window.orderOut(nil)
            }
            removePointerMonitor()
            stopOptionTimer()
            hideCopyGhost()
            hideDeleteTarget()
        }
    }

    func updateGeometry(_ geometry: StageGeometry?) {
        self.geometry = geometry
        reclampAll()
    }

    func screenParametersChanged() {
        reclampAll()
    }

    func refreshSkins(_ skin: VinylSkin) {
        guard skin != self.skin else { return }
        self.skin = skin
        for (id, window) in windows {
            guard let record = store.records.first(where: { $0.id == id }) else { continue }
            let image = DesktopArtworkRenderer.image(
                for: record.style,
                snapshot: record.track,
                artwork: store.artwork(for: record),
                skin: skin
            )
            window.updateImage(image)
        }
    }

    // MARK: - Create

    /// `point == nil` means the packaged-click slot; otherwise the item is
    /// centered on the drop point.
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

        let itemSize = DesktopRecordGeometry.itemSize(for: style)
        let targetScreen: NSScreen?
        let position: CGPoint

        if let point {
            targetScreen = screen(containing: point)
            let visible = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            position = DesktopRecordGeometry.clamp(point, itemSize: itemSize, to: visible)
        } else {
            let target = notchScreen() ?? NSScreen.main
            targetScreen = target
            let frame = target?.frame ?? .zero
            let visible = target?.visibleFrame ?? .zero
            let notchHeight = geometry?.notchHeight ?? max(24, frame.maxY - visible.maxY)
            let screenID = DesktopRecordGeometry.screenID(for: target)
            let index = store.records.filter { $0.screenID == screenID }.count
            position = DesktopRecordGeometry.defaultSlot(
                itemSize: itemSize,
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
            screenID: DesktopRecordGeometry.screenID(for: targetScreen)
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
        startOptionTimerIfNeeded()
    }

    func dragMoved(_ id: UUID) {
        guard let window = windows[id] else { return }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let armed = isInDeleteZone(center)
        window.setDeleteArmed(armed)
        updateDeleteTarget(visible: armed)
    }

    func dragEnded(_ id: UUID, pointer _: CGPoint) {
        draggingID = nil
        updateDeleteTarget(visible: false)
        windows[id]?.setDeleteArmed(false)

        guard let window = windows[id] else {
            pollOptionState()
            return
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)

        if isInDeleteZone(center) {
            delete(id: id, animated: true)
        } else {
            let targetScreen = screen(containing: center) ?? NSScreen.main
            let itemSize = DesktopRecordGeometry.itemSize(for: window.style)
            let visible = targetScreen?.visibleFrame ?? .zero
            let clamped = DesktopRecordGeometry.clamp(center, itemSize: itemSize, to: visible)
            if clamped != center {
                window.setFrameOrigin(CGPoint(
                    x: clamped.x - window.frame.width / 2,
                    y: clamped.y - window.frame.height / 2
                ))
            }
            store.updatePosition(
                id: id,
                position: clamped,
                screenID: DesktopRecordGeometry.screenID(for: targetScreen)
            )
        }

        pollOptionState()
    }

    func delete(id: UUID, animated: Bool) {
        guard let window = windows.removeValue(forKey: id) else { return }
        store.remove(id: id)
        onRecordsChanged?()
        if windows.isEmpty {
            stopOptionTimer()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
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
        stopOptionTimer()
        for window in windows.values {
            window.cancelDrag()
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        store.removeAll()
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

    private func restoreWindows() {
        guard isEnabled else { return }
        for record in store.records where windows[record.id] == nil {
            addWindow(for: record, artwork: store.artwork(for: record))
        }
    }

    private func addWindow(
        for record: DesktopRecord,
        artwork: NSImage?,
        fadeIn: Bool = false
    ) {
        let image = DesktopArtworkRenderer.image(
            for: record.style,
            snapshot: record.track,
            artwork: artwork,
            skin: skin
        )
        let window = DesktopRecordWindow(record: record, image: image)
        window.onDragBegan = { [weak self] id in self?.beginDrag(id) }
        window.onDragMoved = { [weak self] id, _ in self?.dragMoved(id) }
        window.onDragEnded = { [weak self] id, point in self?.dragEnded(id, pointer: point) }
        window.setFrameOrigin(CGPoint(
            x: record.position.x - window.frame.width / 2,
            y: record.position.y - window.frame.height / 2
        ))
        window.alphaValue = fadeIn ? 0 : 1
        windows[record.id] = window
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
        applyInteraction(to: window, optionHeld: optionHeld)
    }

    private func reclampAll() {
        for (id, window) in windows {
            guard let record = store.records.first(where: { $0.id == id }) else { continue }
            let targetScreen = screen(withID: record.screenID)
                ?? screen(containing: record.position)
                ?? NSScreen.main
            let itemSize = DesktopRecordGeometry.itemSize(for: record.style)
            let visible = targetScreen?.visibleFrame ?? .zero
            let clamped = DesktopRecordGeometry.clamp(record.position, itemSize: itemSize, to: visible)
            window.setFrameOrigin(CGPoint(
                x: clamped.x - window.frame.width / 2,
                y: clamped.y - window.frame.height / 2
            ))
            let newScreenID = DesktopRecordGeometry.screenID(for: targetScreen)
            if clamped != record.position || newScreenID != record.screenID {
                store.updatePosition(id: id, position: clamped, screenID: newScreenID)
            }
        }
    }

    // MARK: - Option tracking

    private var optionHeld: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    private func installPointerMonitor() {
        guard pointerMonitor == nil, isEnabled else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pointerMoved(to: NSEvent.mouseLocation)
            }
        }
    }

    private func removePointerMonitor() {
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
            self.pointerMonitor = nil
        }
    }

    private func pointerMoved(to point: CGPoint) {
        let near = windows.values.contains { window in
            let item = DesktopRecordGeometry.itemSize(for: window.style)
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            return abs(point.x - center.x) <= item.width / 2 + 24
                && abs(point.y - center.y) <= item.height / 2 + 24
        }

        if near || draggingID != nil {
            startOptionTimerIfNeeded()
        } else {
            stopOptionTimer()
            for window in windows.values {
                applyInteraction(to: window, optionHeld: false)
            }
        }
    }

    /// The poll runs only while the pointer is near an item. At rest there is
    /// no timer at all, which keeps an idle desktop at effectively zero CPU.
    private func startOptionTimerIfNeeded() {
        guard optionTimer == nil, isEnabled else { return }
        pollOptionState()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOptionState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        optionTimer = timer
    }

    private func stopOptionTimer() {
        optionTimer?.invalidate()
        optionTimer = nil
    }

    private func pollOptionState() {
        let held = optionHeld
        for window in windows.values {
            applyInteraction(to: window, optionHeld: held)
        }
    }

    private func applyInteraction(to window: DesktopRecordWindow, optionHeld: Bool) {
        if window.isDraggingRecord {
            window.ignoresMouseEvents = false
        } else {
            let ignores = !(optionHeld && isEnabled && window.isVisible)
            if ignores {
                window.clearHover()
            }
            window.ignoresMouseEvents = ignores
        }
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
