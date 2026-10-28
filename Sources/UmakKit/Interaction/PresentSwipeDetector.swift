import CoreGraphics

/// Recognises the upward two-finger swipe that brings the active player back
/// to the front while the record is still in the notch.
///
/// The same trackpad stream already opens the record (down), changes tracks
/// (sideways), and closes a pinned record (up). This detector only claims a
/// gesture once it is clearly vertical and upward, so none of those can be
/// stolen by a few points of jitter at the start of a scroll.
struct PresentSwipeDetector {
    enum Outcome: Equatable {
        /// Not a present gesture; the caller's other paths may handle it.
        case ignored
        /// The gesture is a present swipe. Consume the event; do not fire yet.
        case tracking
        /// Fire now. The gesture will not fire again.
        case fired
    }

    private enum Axis {
        case undecided
        case up
        /// The gesture belongs to another meaning (opening, skipping, closing).
        case other
    }

    /// Vertical travel needed before the player is called. Matched to the
    /// horizontal skip distance so both deliberate gestures cost the same.
    static let activationDistance: CGFloat = 90
    /// Upward travel that decides the gesture. Below this it is still trackpad
    /// jitter and either direction may still win.
    static let lockDistance: CGFloat = 8
    /// How much more vertical than lateral the movement must be.
    static let verticalDominance: CGFloat = 1.5
    /// Movement below this does not count toward deciding the axis.
    static let decisionThreshold: CGFloat = 0.5

    private var axis: Axis = .undecided
    private var travel: CGFloat = 0
    private var upProvisional: CGFloat = 0
    private var downProvisional: CGFloat = 0
    private var sideProvisional: CGFloat = 0
    private var hasFired = false

    mutating func reset() {
        axis = .undecided
        travel = 0
        upProvisional = 0
        downProvisional = 0
        sideProvisional = 0
        hasFired = false
    }

    mutating func update(right: CGFloat, pull: CGFloat) -> Outcome {
        // `pull` is positive for the downward gesture that opens the record,
        // so an upward swipe arrives negative.
        let up = -pull
        let lateral = abs(right)

        if hasFired { return .tracking }

        switch axis {
        case .up:
            // The gesture is committed upward for the rest of its life: it
            // either fires or is consumed, but it never opens the record. Net
            // travel means reversing direction gives the distance back, so a
            // wobble near the threshold cannot add up to a false swipe.
            travel = max(0, travel + up)
            guard travel >= Self.activationDistance else { return .tracking }
            hasFired = true
            return .fired

        case .other:
            return .ignored

        case .undecided:
            if up >= Self.decisionThreshold, up >= lateral * Self.verticalDominance {
                upProvisional = max(0, upProvisional + up)
                downProvisional = 0
                sideProvisional = 0
                guard upProvisional >= Self.lockDistance else { return .ignored }
                axis = .up
                travel = upProvisional
                guard travel >= Self.activationDistance else { return .tracking }
                hasFired = true
                return .fired
            }
            if pull >= Self.decisionThreshold, pull >= lateral * Self.verticalDominance {
                downProvisional += pull
                upProvisional = 0
                sideProvisional = 0
                if downProvisional >= Self.lockDistance {
                    axis = .other
                }
                return .ignored
            }
            // Sideways or genuinely diagonal: the skip path owns this gesture
            // once the movement is meaningful, so later upward drift cannot
            // turn it into a present swipe. Small diagonal noise stays
            // undecided so it cannot pre-empt a clear stroke either way.
            if lateral >= Self.decisionThreshold {
                sideProvisional = max(sideProvisional, lateral)
                upProvisional = 0
                downProvisional = 0
                if sideProvisional >= Self.lockDistance {
                    axis = .other
                }
            }
            return .ignored
        }
    }
}
