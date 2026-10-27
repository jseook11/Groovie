import AppKit
import SwiftUI

/// A borderless, non-activating panel that floats above the menu bar.
/// It never steals keyboard focus from whatever the user is doing.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
        isMovableByWindowBackground = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        // Keep the panel out of Mission Control's window list and app switching.
        isExcludedFromWindowsMenu = true
    }
}

/// The hosting view is purely visual; all input is handled by `OverlayContentView`.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Receives hover and drag input over the notch. Never becomes first responder.
final class OverlayContentView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onMouseDownAt: ((CGPoint, TimeInterval, NSEvent.ModifierFlags) -> Void)?
    var onMouseDraggedTo: ((CGPoint, TimeInterval) -> Void)?
    var onMouseUpAt: ((CGPoint, TimeInterval) -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    var onMouseMoved: (() -> Void)?

    private var tracking: NSTrackingArea?

    init(hostingView: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The idle panel's top edge sits on the screen's top edge, which is
        // exactly where the pointer comes to rest when it is pushed all the way
        // up. `CGRect.contains` is half-open and excludes that line, so a click
        // made there would fall through to the menu bar. Keep a 1 pt tolerance
        // so the whole hidden notch strip stays clickable.
        bounds.insetBy(dx: -1, dy: -1).contains(point) ? self : nil
    }

    /// Mouse-move delivery is only useful while a latched record is under the
    /// pointer (label vs vinyl hover feedback). Asking for `.mouseMoved` on the
    /// closed notch made every pointer move across the strip wake the app for a
    /// callback that immediately bailed out. Enter/exit is enough to show the
    /// hover cue.
    private var wantsMouseMoved = false

    func setWantsMouseMoved(_ wants: Bool) {
        guard wants != wantsMouseMoved else { return }
        wantsMouseMoved = wants
        rebuildTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if wantsMouseMoved { options.insert(.mouseMoved) }
        let area = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDownAt?(NSEvent.mouseLocation, event.timestamp, event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDraggedTo?(NSEvent.mouseLocation, event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUpAt?(NSEvent.mouseLocation, event.timestamp)
    }

    override func scrollWheel(with event: NSEvent) {
        // Two-finger trackpad scrolling is an alternative control channel while
        // the pointer is over the notch.
        onScrollWheel?(event)
    }
}
