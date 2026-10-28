import AppKit
import SwiftUI

/// An input-only notch strip on a display that does not host the record.
///
/// Basic notch gestures work on every display: hovering shows the cue, a click
/// toggles playback, a horizontal swipe changes tracks, and an upward swipe
/// brings the player forward. Pulling the record out stays on the display
/// chosen in the status menu, so a downward scroll here does nothing.
@MainActor
final class RemoteNotchInput {
    private let geometry: StageGeometry
    private let layout: VinylLayout
    private let panel: OverlayPanel
    private let hoverModel = RemoteHoverModel()
    private weak var controller: OverlayController?

    private var axis = ScrollAxisLock()
    private var presentSwipe = PresentSwipeDetector()
    private var gestureActive = false
    private var lastEvent: TimeInterval = 0
    private var skipFired = false
    private var noTrackPresentFired = false
    private var pressPoint: CGPoint?

    init(notch: NotchScreen, controller: OverlayController) {
        self.geometry = StageGeometry(notch: notch)
        self.layout = VinylLayout(geometry: geometry)
        self.controller = controller

        let hosting = PassthroughHostingView(rootView: RemoteNotchView(model: hoverModel))
        let content = OverlayContentView(hostingView: hosting)
        let panel = OverlayPanel(frame: geometry.idleFrame)
        panel.contentView = content
        panel.setFrame(geometry.idleFrame, display: false)

        self.panel = panel

        content.onHoverChanged = { [weak self] inside in
            self?.setHover(inside)
        }
        content.onMouseDownAt = { [weak self] point, _, _ in
            self?.handleMouseDown(at: point)
        }
        content.onMouseUpAt = { [weak self] point, _ in
            self?.handleMouseUp(at: point)
        }
        content.onScrollWheel = { [weak self] event in
            self?.handleScroll(event)
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
        NSCursor.arrow.set()
    }

    // MARK: - Pointer

    private func setHover(_ inside: Bool) {
        let accepts = controller?.acceptsIdleSurfaceInput == true
        hoverModel.armed = inside && accepts
        guard inside else {
            NSCursor.arrow.set()
            return
        }
        if accepts, controller?.model.canInteract == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        guard controller?.acceptsIdleSurfaceInput == true else { return }
        controller?.noteInteractionStart()
        pressPoint = point
    }

    private func handleMouseUp(at point: CGPoint) {
        guard let start = pressPoint else { return }
        pressPoint = nil
        guard hypot(point.x - start.x, point.y - start.y) <= layout.clickSlop else { return }
        controller?.clickFromIdleSurface()
    }

    // MARK: - Scroll

    private func handleScroll(_ event: NSEvent) {
        guard let controller, controller.acceptsIdleSurfaceInput else { return }
        guard event.momentumPhase.isEmpty else { return }

        let wallClock = ProcessInfo.processInfo.systemUptime
        let vector = ScrollDirection.physical(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            invertedFromDevice: event.isDirectionInvertedFromDevice,
            precise: event.hasPreciseScrollingDeltas
        )
        guard abs(vector.right) > 0.01 || abs(vector.pull) > 0.01 else { return }

        controller.noteInteractionStart()

        // A wheel stream has no `.began`, so a quiet gap also starts a gesture.
        if event.phase == .began || !gestureActive || wallClock - lastEvent > 0.35 {
            resetGesture()
            gestureActive = true
        }
        lastEvent = wallClock

        // With no track the only useful response is bringing the player
        // forward, once per gesture, matching the closed notch on the host.
        if !controller.model.canInteract {
            if !noTrackPresentFired {
                noTrackPresentFired = true
                controller.presentPlayerFromIdleSurface()
            }
            return
        }

        switch presentSwipe.update(right: vector.right, pull: vector.pull) {
        case .fired:
            controller.presentPlayerFromIdleSurface()
            return
        case .tracking:
            return
        case .ignored:
            break
        }

        if axis.update(right: vector.right, pull: vector.pull) == .horizontal,
           !skipFired,
           abs(axis.horizontalTravel) >= layout.scrollSkipDistance
        {
            skipFired = true
            controller.skipFromIdleSurface(forward: axis.horizontalTravel > 0)
        }
    }

    private func resetGesture() {
        axis.reset()
        presentSwipe.reset()
        skipFired = false
        noTrackPresentFired = false
    }
}

/// The idle strip is only visible while the pointer is over it.
private final class RemoteHoverModel: ObservableObject {
    @Published var armed = false
}

private struct RemoteNotchView: View {
    @ObservedObject var model: RemoteHoverModel

    var body: some View {
        NotchHoverView(armed: model.armed)
    }
}
