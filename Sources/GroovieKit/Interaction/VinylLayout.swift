import CoreGraphics

/// Which part of the pinned record the pointer is over.
enum RecordHover: Equatable {
    case none
    /// The vinyl outside the label: a click puts the record away.
    case vinyl
    /// The centre label: a click toggles playback.
    case label
}

enum VinylPhase: Equatable {
    case idle
    case armed
    case pulling
    case grabbed
    case scrubbing
    case releasing

    var isEngaged: Bool {
        switch self {
        case .pulling, .grabbed, .scrubbing, .releasing: return true
        case .idle, .armed: return false
        }
    }

    var isHoldingRecord: Bool {
        self == .grabbed || self == .scrubbing
    }
}

/// Geometry constants and the pull-distance → exposure curve.
///
/// The record's centre is placed on the emergence line (the bottom of the notch,
/// or the top edge of a display without one) at full extraction. Only the lower
/// half is visible and the upper half disappears behind the edge, which is the
/// physical reading described in the spec.
struct VinylLayout {
    let notchWidth: CGFloat
    /// Height of the black notch shape drawn over the record. Zero when the
    /// display has no camera housing.
    let capHeight: CGFloat
    /// Distance from the top of the window to the emergence line.
    let emergenceInset: CGFloat
    let windowWidth: CGFloat
    let windowHeight: CGFloat

    /// Movement before the pull is recognised at all.
    let pullStartDistance: CGFloat = 8
    /// Pull distance corresponding to a fully extracted record.
    let grabDistance: CGFloat = 80
    /// Magnetic detent: pulling about halfway snaps the record fully out.
    var grabDetent: CGFloat { grabDistance * 0.5 }
    /// Visible depth below the emergence line per point of pull.
    let exposurePerPoint: CGFloat = 1.125
    /// The record is fully extracted when its centre sits exactly on the line.
    var fullExposure: CGFloat { recordRadius }
    var maxExposure: CGFloat { recordRadius }
    let overscrollResistance: CGFloat = 0.18

    /// While the record is held, moving the pointer this far back up snaps it in.
    let mouseDismissDistance: CGFloat = 30
    /// Extra downward travel beyond the detent that confirms (latches) the open
    /// state. Velocity assistance makes a fast pull fill it sooner.
    let confirmDistance: CGFloat = 240
    /// Scroll deltas cover more physical travel than pointer deltas; the scroll
    /// confirm meter is therefore twice as long.
    var scrollConfirmDistance: CGFloat { confirmDistance * 2 }
    /// While confirming, horizontal movement needs 3x the usual dead-zone so
    /// vertical pulling never accidentally scrubs.
    var confirmScrubDeadzone: CGFloat { 90 }

    /// A deliberate horizontal swipe changes tracks. Skipping by accident is
    /// worse than a missed gesture, so this is much longer than the scrub
    /// dead-zone.
    let scrollSkipDistance: CGFloat = 90
    /// Pointer movement allowed in a click before it becomes a drag.
    let clickSlop: CGFloat = 4

    let recordRadius: CGFloat = 90
    let labelRadius: CGFloat = 30
    /// The label is the play/pause target once the record is pinned. Only its
    /// lower half is visible below the notch, so the hit target reaches a little
    /// into the vinyl instead of stopping exactly at the printed edge.
    let labelHitSlop: CGFloat = 12
    var labelHitRadius: CGFloat { labelRadius + labelHitSlop }

    /// 33⅓ RPM.
    let playbackDegreesPerSecond: Double = 200
    let collapseStiffness: Double = 260
    let collapseDamping: Double = 24
    let collapseMaximumTime: Double = 0.42

    init(
        notchWidth: CGFloat,
        capHeight: CGFloat,
        emergenceInset: CGFloat,
        windowWidth: CGFloat = 300,
        windowHeight: CGFloat = 190
    ) {
        self.notchWidth = notchWidth
        self.capHeight = capHeight
        self.emergenceInset = emergenceInset
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
    }

    init(geometry: StageGeometry) {
        self.init(
            notchWidth: geometry.notchWidth,
            capHeight: geometry.hasPhysicalNotch ? geometry.notchHeight : 0,
            emergenceInset: geometry.emergenceInset,
            windowWidth: geometry.windowWidth,
            windowHeight: geometry.windowHeight
        )
    }

    /// How far the lowest point of the record sits below the emergence line.
    /// The pull stops when the centre reaches the line, so the record never
    /// drifts vertically while it is being scrubbed.
    func exposure(forPullDistance distance: CGFloat) -> CGFloat {
        let linear = max(0, distance) * exposurePerPoint
        guard linear > fullExposure else { return linear }
        return min(maxExposure, fullExposure + (linear - fullExposure) * overscrollResistance)
    }

    /// The record centre in top-left content coordinates.
    func recordCenterY(exposure: CGFloat) -> CGFloat {
        emergenceInset + exposure - recordRadius
    }

    func recordCenter(in size: CGSize, exposure: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2, y: recordCenterY(exposure: exposure))
    }

    /// Whether a point in top-left content coordinates lands on the label.
    func isOnLabel(_ point: CGPoint, exposure: CGFloat) -> Bool {
        hoverRegion(at: point, exposure: exposure) == .label
    }

    /// Classify a point for hover feedback and the click target it represents.
    func hoverRegion(at point: CGPoint, exposure: CGFloat) -> RecordHover {
        let center = CGPoint(x: windowWidth / 2, y: recordCenterY(exposure: exposure))
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance <= labelHitRadius { return .label }
        if distance <= recordRadius { return .vinyl }
        return .none
    }

    var hasNotchCap: Bool { capHeight > 0.5 }
}
