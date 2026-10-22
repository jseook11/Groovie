import AppKit

/// One desktop decoration. The window is exactly the rendered image's size,
/// including its transparent shadow margin, and accepts mouse events only on
/// the object's silhouette.
///
/// Plain clicks raise the item. Option+click toggles the sleeve's record, and
/// Option+drag moves the item.
final class DesktopRecordWindow: NSPanel {
    let recordID: UUID
    let style: DesktopRecordStyle
    /// Whether a sleeve is showing its record. Always true for a disc.
    let recordOut: Bool

    var onDragBegan: ((UUID) -> Void)?
    var onDragMoved: ((UUID, CGPoint) -> Void)?
    var onDragEnded: ((UUID, CGPoint) -> Void)?
    var onClicked: ((UUID) -> Void)?
    /// A plain click without Option. The controller brings the window forward;
    /// no drag begins.
    var onRaise: ((UUID) -> Void)?

    private let baseLevel: NSWindow.Level
    private let recordView: DesktopRecordContentView
    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var mouseUpMonitor: Any?
    private(set) var isDraggingRecord = false

    /// Just above the Finder desktop icons, still far below normal application
    /// windows. Sitting exactly at the icon level lets Finder's desktop window
    /// come forward when another app gains focus and swallow the item's
    /// clicks; one level higher keeps the item interactive while the desktop is
    /// visible.
    static let desktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
    )

    init(record: DesktopRecord, image: NSImage) {
        recordID = record.id
        style = record.style
        recordOut = record.recordOut
        baseLevel = Self.desktopLevel

        let size = DesktopRecordGeometry.windowSize(
            for: record.style,
            recordOut: record.recordOut
        )
        recordView = DesktopRecordContentView(
            frame: CGRect(origin: .zero, size: size),
            image: image,
            style: record.style,
            recordOut: record.recordOut
        )

        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = baseLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        // Always accept events. If the item ignored them unless Option was
        // already held, pressing Option while the pointer rests on the item
        // would not take effect until it left and re-entered. The content view
        // limits hit testing to the silhouette; clicks on the transparent
        // shadow margin are deliberately still handled by this window for now.
        ignoresMouseEvents = false
        isExcludedFromWindowsMenu = true
        contentView = recordView

        recordView.onMouseDown = { [weak self] event in self?.beginDrag(with: event) }
        recordView.onRaise = { [weak self] in
            guard let self else { return }
            self.onRaise?(self.recordID)
        }
        recordView.onMouseDragged = { [weak self] _ in self?.updateDrag() }
        recordView.onMouseUp = { [weak self] _ in self?.endDrag() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
    }

    func updateImage(_ image: NSImage) {
        recordView.updateImage(image)
    }

    /// Stop an in-flight drag without reporting a drop. Used when the whole
    /// controller is disabled or shutting down.
    func cancelDrag() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        guard isDraggingRecord else {
            recordView.restoreCursor()
            return
        }
        isDraggingRecord = false
        dragStartMouse = nil
        dragStartOrigin = nil
        level = baseLevel
        recordView.setDragging(false)
        recordView.setDeleteArmed(false)
        recordView.restoreCursor()
    }

    func setDeleteArmed(_ armed: Bool) {
        recordView.setDeleteArmed(armed)
    }

    // MARK: - Drag

    private func beginDrag(with event: NSEvent) {
        // Ignore the second click of a double-click: otherwise a disc can turn
        // into a sleeve and immediately close again, with different results
        // depending on where the second click lands.
        guard event.modifierFlags.contains(.option),
              event.clickCount <= 1,
              !isDraggingRecord
        else { return }
        isDraggingRecord = true
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = frame.origin
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        recordView.setDragging(true)
        NSCursor.closedHand.set()
        onDragBegan?(recordID)

        // AppKit normally keeps sending drags to this window. The global
        // monitor is a safety net for a mouse-up that arrives after a space or
        // app switch.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated { self?.endDrag() }
        }
    }

    private func updateDrag() {
        guard isDraggingRecord,
              let startMouse = dragStartMouse,
              let startOrigin = dragStartOrigin
        else { return }

        let now = NSEvent.mouseLocation
        let origin = CGPoint(
            x: startOrigin.x + (now.x - startMouse.x),
            y: startOrigin.y + (now.y - startMouse.y)
        )
        setFrameOrigin(origin)
        onDragMoved?(recordID, now)
    }

    private func endDrag() {
        guard isDraggingRecord else { return }
        isDraggingRecord = false
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        let end = NSEvent.mouseLocation
        let travel = dragStartMouse.map {
            hypot(end.x - $0.x, end.y - $0.y)
        } ?? 0
        dragStartMouse = nil
        dragStartOrigin = nil
        level = baseLevel
        recordView.setDragging(false)
        recordView.restoreCursor()

        if travel <= 4 {
            onClicked?(recordID)
        } else {
            onDragEnded?(recordID, end)
        }
    }
}

/// Layer-backed still image plus a drag/delete ring. The silhouette decides
/// where clicks land. Nothing redraws on a timer; the layer contents change
/// only with the image, the ring state, or the Option-hover lift.
final class DesktopRecordContentView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onRaise: (() -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    private let imageLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let silhouettePath: CGPath
    private let ringPath: CGPath
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var deleteArmed = false
    private var dragging = false

    init(frame: CGRect, image: NSImage, style: DesktopRecordStyle, recordOut: Bool) {
        let padding = DesktopRecordGeometry.shadowPadding

        // Geometry rects are in item coordinates (origin at the visible
        // object's bottom-left). The content view adds the shadow margin that
        // the window reserves around the item.
        let cover = DesktopRecordGeometry.coverRect(
            for: style,
            recordOut: recordOut
        ).offsetBy(dx: padding, dy: padding)
        let disc = DesktopRecordGeometry.discRect(
            for: style,
            recordOut: recordOut
        ).offsetBy(dx: padding, dy: padding)

        let silhouette = CGMutablePath()
        let ring: CGPath
        switch style {
        case .disc:
            silhouette.addEllipse(in: disc)
            ring = CGPath(ellipseIn: disc.insetBy(dx: -3, dy: -3), transform: nil)
        case .sleeve:
            // A closed sleeve is just the cover. An open one is the cover plus
            // the disc that protrudes to its right.
            silhouette.addRect(cover)
            let coverRing = CGPath(
                roundedRect: cover.insetBy(dx: -3, dy: -3),
                cornerWidth: 5,
                cornerHeight: 5,
                transform: nil
            )
            if recordOut {
                silhouette.addEllipse(in: disc)
                ring = coverRing.union(
                    CGPath(ellipseIn: disc.insetBy(dx: -3, dy: -3), transform: nil)
                )
            } else {
                ring = coverRing
            }
        }
        silhouettePath = silhouette
        ringPath = ring

        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        imageLayer.frame = bounds
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        imageLayer.contents = Self.cgImage(from: image)
        layer?.addSublayer(imageLayer)

        ringLayer.frame = bounds
        ringLayer.path = ringPath
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.42).cgColor
        ringLayer.lineWidth = 1
        ringLayer.opacity = 0
        layer?.addSublayer(ringLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks outside the visible object fall through the view. The window
    /// still owns the transparent margin; true click-through during overlap is
    /// a separate, deferred problem.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return silhouettePath.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: silhouettePath.boundingBoxOfPath.insetBy(dx: -2, dy: -2),
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateOptionHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateOptionHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateRing()
        updateLift()
        if !dragging {
            NSCursor.arrow.set()
        }
    }

    /// Option hover lifts the item and shows the open-hand cursor. A plain
    /// hover leaves it still. AppKit only delivers these events while this
    /// window is the topmost one under the pointer, so a covered item stays
    /// quiet.
    private func updateOptionHover(with event: NSEvent) {
        // The tracking area is the silhouette's bounding box, which includes
        // transparent corners (notably around a disc and beside the exposed
        // vinyl). Require the pointer to be on the object itself so the lift
        // and open-hand cursor never appear over empty space.
        let local = convert(event.locationInWindow, from: nil)
        let option = event.modifierFlags.contains(.option)
            && silhouettePath.contains(local)
        if hovered != option {
            hovered = option
            updateRing()
            updateLift()
        }
        if dragging {
            NSCursor.closedHand.set()
        } else if option {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            onMouseDown?(event)
        } else {
            onRaise?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event)
    }

    func updateImage(_ image: NSImage) {
        imageLayer.contents = Self.cgImage(from: image)
    }

    func setDragging(_ dragging: Bool) {
        self.dragging = dragging
        updateRing()
        updateLift()
    }

    func setDeleteArmed(_ armed: Bool) {
        deleteArmed = armed
        updateRing()
    }

    /// Reapply the cursor for the current hover/drag state. Used after a drag
    /// ends so the open hand comes back while Option is still held.
    func restoreCursor() {
        if dragging {
            NSCursor.closedHand.set()
        } else if hovered && NSEvent.modifierFlags.contains(.option) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// The ring marks a drag or an armed delete target only. Option hover is
    /// communicated by the lift, not an outline.
    private func updateRing() {
        let visible = dragging || deleteArmed
        ringLayer.opacity = visible ? 1 : 0
        if deleteArmed {
            ringLayer.strokeColor = NSColor(
                srgbRed: 1,
                green: 0.56,
                blue: 0.45,
                alpha: 0.9
            ).cgColor
            ringLayer.lineWidth = 1.6
        } else {
            ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.42).cgColor
            ringLayer.lineWidth = 1
        }
        imageLayer.opacity = deleteArmed ? 0.72 : 1
    }

    /// A barely-there scale change makes the item feel picked up under Option.
    /// The image layer scales around its own centre; the shadow padding scales
    /// with it.
    private func updateLift() {
        let scale: CGFloat
        if dragging {
            scale = 1.04
        } else if hovered {
            scale = 1.02
        } else {
            scale = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let transform = CATransform3DMakeScale(scale, scale, 1)
        imageLayer.transform = transform
        // The ring is a sibling in view coordinates. Scale it with the image
        // so it hugs the lifted edge instead of being swallowed by it.
        ringLayer.transform = transform
        CATransaction.commit()
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
