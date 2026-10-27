import Foundation
import QuartzCore

/// How the record is turning.
///
/// Playback rotation is run by Core Animation in `RotatingDiscView`, but
/// `OverlayController` needs the same angle the instant the pointer takes the
/// disc over. Both sides therefore derive the angle from a reference instead of
/// sampling the layer: the reference carries an angle and the wall-clock time
/// it was current, so the disc is always a function of that pair.
enum DiscSpin: Equatable {
    /// Not rotating; the model's `angle` is authoritative.
    case stopped
    /// Spinning up to playback speed from `SpinUp`.
    case spinningUp(SpinUp)
    /// Constant playback speed from `reference`.
    case spinning(SpinReference)
    /// Coasting to rest after playback paused.
    case coasting(SpinDown)

    /// True whenever playback motion is being driven, at speed or getting
    /// there. `syncSpin` uses this so an update in the middle of a spin-up
    /// does not restart the launch.
    var isSpinning: Bool {
        switch self {
        case .spinningUp, .spinning: return true
        case .stopped, .coasting: return false
        }
    }
}

/// An angle and the time it was current, on the `CACurrentMediaTime` clock.
struct SpinReference: Equatable {
    var angle: Double
    var since: CFTimeInterval
}

/// The spin-up when playback starts: the angle it began from, when, and the
/// speed it already had (non-zero when a coast is being reversed).
struct SpinUp: Equatable {
    var angle: Double
    var since: CFTimeInterval
    var startSpeed: Double
}

/// The spin-down after a pause: the angle playback stopped at, when, and the
/// speed the platter had at that moment (a speed-up can be braked too).
struct SpinDown: Equatable {
    var angle: Double
    var since: CFTimeInterval
    var speed: Double
}

/// Turntable spin-up shared by the model and the layer animation.
///
/// A motor with a platter does not reach speed instantly: velocity approaches
/// 33⅓ RPM exponentially. Starting from rest most of the speed arrives in the
/// first half-second, and the last few percent fade in. The same curve handles
/// resuming during a coast, where `startSpeed` is whatever speed the brake had
/// left, so reversing direction never drops the disc to zero first.
enum SpinUpCurve {
    /// Time for the speed deficit to fall to about 37 %.
    static let timeConstant: Double = 0.22
    /// The deficit is under 1 % here; the model hands over to a constant-speed
    /// rotation and the layer animation ends.
    static let settleTime: Double = 1.0

    /// Degrees per second `elapsed` seconds after the launch.
    static func speed(target: Double, startSpeed: Double, elapsed: Double) -> Double {
        let t = max(elapsed, 0)
        return target + (startSpeed - target) * exp(-t / timeConstant)
    }

    /// Degrees travelled `elapsed` seconds after the launch. It stays linear
    /// at the target speed afterwards, so sampling past `settleTime` is exact.
    static func travelled(target: Double, startSpeed: Double, elapsed: Double) -> Double {
        let t = max(elapsed, 0)
        return target * t + (startSpeed - target) * timeConstant * (1 - exp(-t / timeConstant))
    }

    /// The disc angle `elapsed` seconds after the launch, in 0..<360.
    static func angle(
        from startAngle: Double,
        target: Double,
        startSpeed: Double,
        elapsed: Double
    ) -> Double {
        (startAngle + travelled(target: target, startSpeed: startSpeed, elapsed: elapsed))
            .truncatingRemainder(dividingBy: 360)
    }
}

/// Turntable spin-down shared by the model and the layer animation.
///
/// A platter with mass does not stop dead. The brake takes most of the speed
/// away quickly and the last of it fades out, so velocity decays
/// exponentially. At 33⅓ RPM the disc travels ω₀·τ — about 56° — before it
/// comes to rest, which reads as a rapid but heavy stop rather than a freeze.
enum SpinDownCurve {
    /// Time for velocity to fall to about 37 %, short enough to read as a brake.
    static let timeConstant: Double = 0.28
    /// By this point less than 1 % of the travel is left; the disc is still.
    static let settleTime: Double = 1.4

    /// Degrees per second `elapsed` seconds after the brake.
    static func speed(startSpeed: Double, elapsed: Double) -> Double {
        startSpeed * exp(-max(elapsed, 0) / timeConstant)
    }

    /// Degrees travelled `elapsed` seconds after the brake.
    static func travelled(startSpeed: Double, elapsed: Double) -> Double {
        let t = min(max(elapsed, 0), settleTime)
        return startSpeed * timeConstant * (1 - exp(-t / timeConstant))
    }

    /// The disc angle `elapsed` seconds after the brake, in 0..<360.
    static func angle(
        from startAngle: Double,
        startSpeed: Double,
        elapsed: Double
    ) -> Double {
        (startAngle + travelled(startSpeed: startSpeed, elapsed: elapsed))
            .truncatingRemainder(dividingBy: 360)
    }
}
