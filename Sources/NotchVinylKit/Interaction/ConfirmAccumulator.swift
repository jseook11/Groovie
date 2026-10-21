import Foundation

/// Velocity-assisted "pull further to confirm" meter.
///
/// The nominal distance is generous (240 pt), so a slow, deliberate pull needs
/// the whole travel. A faster pull multiplies each point of travel (up to ~3.2×),
/// which keeps a quick flick comfortable without making an accidental small drag
/// latch the record. Upward movement removes the raw distance again.
struct ConfirmAccumulator {
    private(set) var distance: CGFloat = 240
    private(set) var accumulated: CGFloat = 0
    private(set) var speed: Double = 0

    private var lastExtra: CGFloat?
    private var lastTimestamp: TimeInterval?

    var progress: Double {
        guard distance > 0 else { return 1 }
        return Double(min(max(accumulated, 0), distance) / distance)
    }

    var isComplete: Bool { accumulated >= distance }

    mutating func begin(extra: CGFloat, timestamp: TimeInterval, distance: CGFloat) {
        self.distance = max(1, distance)
        accumulated = 0
        speed = 0
        lastExtra = extra
        lastTimestamp = timestamp
    }

    /// Feed the raw extra downward travel. Returns true when the meter is full.
    mutating func update(extra: CGFloat, timestamp: TimeInterval) -> Bool {
        guard let lastExtra, let lastTimestamp else {
            self.lastExtra = extra
            self.lastTimestamp = timestamp
            return false
        }

        let dt = max(timestamp - lastTimestamp, 0.001)
        let delta = extra - lastExtra
        let rawSpeed = min(max(abs(Double(delta) / dt), 0), 8000)

        // Fast attack, slower release: a flick is rewarded immediately and the
        // multiplier fades when the hand slows down.
        let timeConstant: TimeInterval = rawSpeed > speed ? 0.045 : 0.12
        let alpha = 1 - exp(-dt / timeConstant)
        speed += alpha * (rawSpeed - speed)

        if delta > 0 {
            accumulated += delta * CGFloat(accelerationFactor(forSpeed: speed))
        } else if delta < 0 {
            accumulated = max(0, accumulated + delta)
        }

        self.lastExtra = extra
        self.lastTimestamp = timestamp
        return isComplete
    }

    mutating func reset() {
        accumulated = 0
        speed = 0
        lastExtra = nil
        lastTimestamp = nil
    }

    func accelerationFactor(forSpeed speed: Double) -> Double {
        let normalized = min(max(speed, 0) / 1800, 1)
        return 1 + 2.2 * pow(normalized, 1.5)
    }
}
