import QuartzCore

/// Playback rotation of the disc over time.
///
/// The visible rotation is a Core Animation animation running on the render
/// server, so the controller never updates `angle` every frame. This value is
/// the single description both that animation and the controller's angle
/// sampling are built from: a scrub that takes over mid-spin starts exactly
/// where the disc was drawn.
enum SpinMotion: Equatable {
    case stopped
    /// A turntable run-up: velocity eases from `velocity` to `topSpeed`.
    case starting(
        fromAngle: Double,
        velocity: Double,
        topSpeed: Double,
        startTime: CFTimeInterval,
        duration: Double
    )
    /// Constant playback speed.
    case steady(fromAngle: Double, speed: Double, startTime: CFTimeInterval)
    /// A hard brake: velocity falls to zero quickly.
    case stopping(
        fromAngle: Double,
        velocity: Double,
        startTime: CFTimeInterval,
        duration: Double
    )

    /// True while playback wants the record spinning. A stop already in flight
    /// counts as off, so resuming during one starts from the speed it has left.
    var isSpinning: Bool {
        switch self {
        case .starting, .steady: return true
        case .stopped, .stopping: return false
        }
    }

    /// True for any known motion, including a stop that has not finished yet.
    var isRotating: Bool {
        if case .stopped = self { return false }
        return true
    }

    func angle(at time: CFTimeInterval) -> Double {
        switch self {
        case .stopped:
            return 0
        case let .steady(fromAngle, speed, startTime):
            return fromAngle + speed * max(0, time - startTime)
        case let .starting(fromAngle, velocity, topSpeed, startTime, duration):
            return fromAngle + Self.runUpDelta(
                time: time,
                velocity: velocity,
                topSpeed: topSpeed,
                startTime: startTime,
                duration: duration
            )
        case let .stopping(fromAngle, velocity, startTime, duration):
            let u = Self.progress(time: time, startTime: startTime, duration: duration)
            // Integral of v0 · (1 − smoothstep): v0·T·(u − u³ + u⁴/2).
            return fromAngle + velocity * duration * (u - u * u * u + u * u * u * u / 2)
        }
    }

    func velocity(at time: CFTimeInterval) -> Double {
        switch self {
        case .stopped:
            return 0
        case let .steady(_, speed, _):
            return speed
        case let .starting(_, velocity, topSpeed, startTime, duration):
            let u = Self.progress(time: time, startTime: startTime, duration: duration)
            return velocity + (topSpeed - velocity) * Self.smoothstep(u)
        case let .stopping(_, velocity, startTime, duration):
            let u = Self.progress(time: time, startTime: startTime, duration: duration)
            return velocity * (1 - Self.smoothstep(u))
        }
    }

    // MARK: - Curves

    private static func progress(
        time: CFTimeInterval,
        startTime: CFTimeInterval,
        duration: Double
    ) -> Double {
        let span = max(duration, 0.0001)
        return min(max((time - startTime) / span, 0), 1)
    }

    private static func smoothstep(_ u: Double) -> Double {
        u * u * (3 - 2 * u)
    }

    /// Integral of `v0 + Δv · smoothstep(u)` over the ramp, continuing at
    /// `topSpeed` once it completes.
    private static func runUpDelta(
        time: CFTimeInterval,
        velocity: Double,
        topSpeed: Double,
        startTime: CFTimeInterval,
        duration: Double
    ) -> Double {
        let span = max(duration, 0.0001)
        let tau = max(0, time - startTime)
        let clamped = min(tau, span)
        let u = clamped / span

        // ∫ smoothstep = u³ − u⁴/2.
        var delta = velocity * clamped
            + (topSpeed - velocity) * span * (u * u * u - u * u * u * u / 2)
        if tau > span {
            delta += topSpeed * (tau - span)
        }
        return delta
    }
}
