import AppKit

/// One desktop decoration. The window is exactly the size of the rendered
/// image, including its transparent shadow margin, and accepts mouse events only
/// while Option is held (the controller toggles `ignoresMouseEvents`).
final class DesktopRecordWindow: NSPanel {
    let recordID: UUID
    let style: DesktopRecordStyle

    var onDragBegan: ((UUID) -> Void)?
    var onDragMoved: ((UUID, CGPoint) -> Void)?
    var onDragEnded: ((UUID, CGPoint) -> Void)?

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
        baseLevel = Self.desktopLevel

        let size = DesktopRecordGeometry.windowSize(for: record.style)
        recordView = DesktopRecordContentView(
            frame: CGRect(origin: .zero, size: size),
            image: image,
            style: record.style
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
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        contentView = recordView

        recordView.onMouseDown = { [weak self] event in self?.beginDrag(with: event) }
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

    func clearHover() {
        recordView.clearHover()
    }

    /// Stop an in-flight drag without reporting a drop. Used when the whole
    /// controller is disabled or shutting down.
    func cancelDrag() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        guard isDraggingRecord else { return }
        isDraggingRecord = false
        dragStartMouse = nil
        dragStartOrigin = nil
        level = baseLevel
        recordView.setDragging(false)
        recordView.setDeleteArmed(false)
        NSCursor.arrow.set()
    }

    func setDeleteArmed(_ armed: Bool) {
        recordView.setDeleteArmed(armed)
    }

    // MARK: - Drag

    private func beginDrag(with event: NSEvent) {
        guard event.modifierFlags.contains(.option), !isDraggingRecord else { return }
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
        dragStartMouse = nil
        dragStartOrigin = nil
        level = baseLevel
        recordView.setDragging(false)
        NSCursor.arrow.set()
        onDragEnded?(recordID, NSEvent.mouseLocation)
    }
}

/// Layer-backed still image plus a hover/delete ring. Nothing here redraws on a
/// timer; the layer contents are replaced only when the image or ring changes.
final class DesktopRecordContentView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    private let imageLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let itemRect: CGRect
    private let ringPath: CGPath
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var deleteArmed = false
    private var dragging = false

    init(frame: CGRect, image: NSImage, style: DesktopRecordStyle) {
        let padding = DesktopRecordGeometry.shadowPadding
        itemRect = CGRect(
            x: padding,
            y: padding,
            width: max(0, frame.width - padding * 2),
            height: max(0, frame.height - padding * 2)
        )

        let ringRect = itemRect.insetBy(dx: -3, dy: -3)
        switch style {
        case .disc:
            ringPath = CGPath(ellipseIn: ringRect, transform: nil)
        case .sleeve:
            ringPath = CGPath(
                roundedRect: ringRect,
                cornerWidth: 5,
                cornerHeight: 5,
                transform: nil
            )
        }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateRing()
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateRing()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
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

    func clearHover() {
        guard hovered else { return }
        hovered = false
        updateRing()
        NSCursor.arrow.set()
    }

    func setDragging(_ dragging: Bool) {
        self.dragging = dragging
        updateRing()
    }

    func setDeleteArmed(_ armed: Bool) {
        deleteArmed = armed
        updateRing()
    }

    private func updateRing() {
        let visible = hovering || dragging
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

    private var hovering: Bool {
        hovered || dragging
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
