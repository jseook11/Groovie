import Foundation

/// Tunable constants for the velocity-sensitive scrubbing model.
///
///     Δt = −Δx · S(|vx|)
///
/// `S` is a smooth, monotonically increasing curve (seconds of audio per point of
/// horizontal pointer travel). Slow, deliberate movement gives roughly 100 ms of
/// resolution; fast flicks are amplified, but capped.
struct ScrubTuning: Equatable {
    /// Seconds of audio per point at zero speed.
    var minSensitivity: Double = 0.0075
    /// Seconds of audio per point at or above `speedAtMaxSensitivity`.
    var maxSensitivity: Double = 0.9
    var speedAtMaxSensitivity: Double = 7000
    /// > 1 keeps the low-speed region gentle and makes fast movement accelerate.
    var sensitivityExponent: Double = 1.9
    /// Filtering constants for the pointer speed estimate (seconds).
    var attackTime: Double = 0.045
    var releaseTime: Double = 0.14
    /// How far the record visually turns per point of horizontal travel.
    var degreesPerPoint: Double = 0.8
    /// Keep a little headroom before a seek can roll over to the next track.
    var endGuard: Double = 0.15

    static let `default` = ScrubTuning()
}

struct ScrubResult: Equatable {
    /// Seconds relative to the position at grab time (clamped to the track).
    var delta: Double
    var position: Double
    /// Accumulated visual rotation since grab time, degrees (counter-clockwise negative).
    var angleDelta: Double
    /// Smoothed horizontal pointer speed, points / second.
    var speed: Double
    var sensitivity: Double
    var hitStart: Bool
    var hitEnd: Bool
}

/// Pure model of one grab-and-rotate gesture. Feed it pointer samples; it never
/// touches audio or UI, which makes the whole feel testable.
struct ScrubEngine {
    var tuning: ScrubTuning

    private(set) var basePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var accumulated: Double = 0
    private(set) var angleDelta: Double = 0
    private(set) var filteredSpeed: Double = 0
    private(set) var isActive = false

    private var lastX: Double = 0
    private var lastTimestamp: TimeInterval = 0
    private var hasVelocity = false

    init(tuning: ScrubTuning = .default) {
        self.tuning = tuning
    }

    mutating func begin(x: Double, timestamp: TimeInterval, basePosition: Double, duration: Double) {
        self.basePosition = basePosition
        self.duration = duration
        self.accumulated = 0
        self.angleDelta = 0
        self.filteredSpeed = 0
        self.lastX = x
        self.lastTimestamp = timestamp
        self.hasVelocity = false
        self.isActive = true
    }

    mutating func end() {
        isActive = false
    }

    /// Sensitivity S(v), in seconds per point.
    func sensitivity(forSpeed speed: Double) -> Double {
        let v = min(max(speed, 0), tuning.speedAtMaxSensitivity)
        let u = v / tuning.speedAtMaxSensitivity
        return tuning.minSensitivity
            + (tuning.maxSensitivity - tuning.minSensitivity) * pow(u, tuning.sensitivityExponent)
    }

    mutating func update(x: Double, timestamp: TimeInterval) -> ScrubResult {
        guard isActive else {
            return ScrubResult(
                delta: accumulated,
                position: position(forDelta: accumulated),
                angleDelta: angleDelta,
                speed: filteredSpeed,
                sensitivity: sensitivity(forSpeed: filteredSpeed),
                hitStart: false,
                hitEnd: false
            )
        }

        let dt = timestamp - lastTimestamp
        let dx = x - lastX
        defer {
            lastX = x
            lastTimestamp = timestamp
        }

        guard dt > 0.0001 else {
            return currentResult(hitStart: false, hitEnd: false)
        }

        let rawSpeed = min(abs(dx / dt), 20_000)
        let timeConstant = rawSpeed > filteredSpeed ? tuning.attackTime : tuning.releaseTime
        let alpha = 1 - exp(-dt / max(timeConstant, 0.001))
        if hasVelocity {
            filteredSpeed += alpha * (rawSpeed - filteredSpeed)
        } else {
            filteredSpeed = rawSpeed
            hasVelocity = true
        }

        let s = sensitivity(forSpeed: filteredSpeed)
        let rawDelta = -dx * s

        let maxDelta = max(0, max(0, duration - tuning.endGuard) - basePosition)
        let unclamped = accumulated + rawDelta
        let clamped = min(max(unclamped, -basePosition), maxDelta)
        let hitStart = clamped <= -basePosition + 0.000_001 && rawDelta < 0
        let hitEnd = clamped >= maxDelta - 0.000_001 && rawDelta > 0

        // The disc stops against the end of the track instead of continuing to spin.
        let trackEnd = max(0, duration - tuning.endGuard)
        let currentPosition = position(forDelta: accumulated)
        let pushingPastStart = currentPosition <= 0.000_1 && rawDelta < 0
        let pushingPastEnd = currentPosition >= trackEnd - 0.000_1 && rawDelta > 0
        if !pushingPastStart && !pushingPastEnd {
            angleDelta -= dx * tuning.degreesPerPoint
        }

        accumulated = clamped

        return currentResult(hitStart: hitStart, hitEnd: hitEnd)
    }

    private func position(forDelta delta: Double) -> Double {
        min(max(basePosition + delta, 0), max(0, duration - tuning.endGuard))
    }

    private func currentResult(hitStart: Bool, hitEnd: Bool) -> ScrubResult {
        ScrubResult(
            delta: accumulated,
            position: position(forDelta: accumulated),
            angleDelta: angleDelta,
            speed: filteredSpeed,
            sensitivity: sensitivity(forSpeed: filteredSpeed),
            hitStart: hitStart,
            hitEnd: hitEnd
        )
    }
}
