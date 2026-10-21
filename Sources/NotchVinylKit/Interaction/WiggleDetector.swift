import Foundation

/// Detects a deliberate left-right shake of the pointer / scroll gesture.
///
/// A wiggle is a sequence of alternating horizontal strokes inside a short time
/// window. Tiny jitter and a single precise direction change do not count; this
/// is meant to be an intentional "undo the seek" gesture.
struct WiggleDetector {
    var minimumStroke: Double = 8
    var window: TimeInterval = 1.0
    var requiredReversals: Int = 4

    private var lastX: Double?
    private var direction = 0
    private var extreme: Double = 0
    private var reversalTimes: [TimeInterval] = []

    mutating func reset() {
        lastX = nil
        direction = 0
        extreme = 0
        reversalTimes.removeAll()
    }

    /// Feed the current horizontal coordinate. Returns true exactly once when a
    /// wiggle is recognised (the detector resets itself).
    mutating func update(x: Double, timestamp: TimeInterval) -> Bool {
        guard let last = lastX else {
            lastX = x
            extreme = x
            return false
        }
        lastX = x

        let delta = x - last
        guard abs(delta) > 0.0001 else { return false }
        let newDirection = delta > 0 ? 1 : -1

        if direction == 0 {
            direction = newDirection
            extreme = x
            return false
        }

        if newDirection == direction {
            if (newDirection > 0 && x > extreme) || (newDirection < 0 && x < extreme) {
                extreme = x
            }
            return false
        }

        // Direction flipped. Only count it if the stroke away from the previous
        // turning point is meaningful; otherwise it is hand jitter.
        let stroke = abs(x - extreme)
        guard stroke >= minimumStroke else { return false }

        direction = newDirection
        extreme = x
        reversalTimes.append(timestamp)
        reversalTimes.removeAll { timestamp - $0 > window }

        if reversalTimes.count >= requiredReversals {
            reset()
            return true
        }
        return false
    }
}

/// Converts AppKit scroll deltas into the controller's gesture axes.
///
/// `right` is positive for the gesture that scrubs right (rewind).
/// `pull` is positive for the gesture that extracts the record. The vertical
/// sign is deliberately the opposite of the first implementation: on the target
/// trackpad, the natural "scroll down" gesture extracts the disc.
/// `isDirectionInvertedFromDevice` is true when "natural scrolling" is enabled;
/// AppKit has already inverted the deltas in that case.
enum ScrollDirection {
    static func physical(
        deltaX: CGFloat,
        deltaY: CGFloat,
        invertedFromDevice: Bool,
        precise: Bool
    ) -> (right: CGFloat, pull: CGFloat) {
        let right = (invertedFromDevice ? deltaX : -deltaX)
        let pull = (invertedFromDevice ? deltaY : -deltaY)
        let wheelScale: CGFloat = precise ? 1 : 6
        return (right * wheelScale, pull * wheelScale)
    }
}
