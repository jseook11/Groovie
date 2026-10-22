import CoreGraphics

/// Locks a two-finger scroll gesture to one axis as soon as the movement is
/// unambiguous.
///
/// The notch uses the vertical axis to pull the record out and the horizontal
/// axis to change tracks. Letting the meaning flip mid-gesture would let an
/// intended pull skip a track (or the reverse), so the first clear direction
/// wins for the rest of the gesture.
struct ScrollAxisLock: Equatable {
    enum Axis: Equatable {
        case undecided
        case horizontal
        case vertical
    }

    private(set) var axis: Axis = .undecided
    /// Signed horizontal travel since the axis locked. Positive is right.
    private(set) var horizontalTravel: CGFloat = 0

    /// A track change needs a clearly horizontal gesture. An accidental skip
    /// is worse than a swipe that does nothing.
    static let horizontalDominance: CGFloat = 1.5
    /// Trackpad noise below this does not decide the axis.
    static let decisionThreshold: CGFloat = 0.5

    mutating func update(right: CGFloat, pull: CGFloat) -> Axis {
        switch axis {
        case .horizontal:
            horizontalTravel += right
        case .vertical:
            break
        case .undecided:
            let horizontal = abs(right)
            let vertical = abs(pull)
            guard max(horizontal, vertical) >= Self.decisionThreshold else { return axis }
            if horizontal >= vertical * Self.horizontalDominance {
                axis = .horizontal
                horizontalTravel = right
            } else if vertical > horizontal {
                axis = .vertical
            }
            // A diagonal that is neither clearly horizontal nor vertical stays
            // undecided until a later event or the gesture ends.
        }
        return axis
    }

    mutating func reset() {
        axis = .undecided
        horizontalTravel = 0
    }
}
