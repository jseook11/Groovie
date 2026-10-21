import Foundation

/// Headless checks for the pure interaction model. Run with `--self-test`.
/// (XCTest is not part of the Command Line Tools installation.)
public enum SelfChecks {
    public static func run() -> Int {
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func approx(_ a: Double, _ b: Double, _ epsilon: Double = 0.0001) -> Bool {
            abs(a - b) < epsilon
        }

        // MARK: Sensitivity

        let tuning = ScrubTuning.default
        let engineForCurve = ScrubEngine()
        var previous = -Double.infinity
        for speed in [0.0, 10, 100, 500, 1500, 4000, 7000] {
            let value = engineForCurve.sensitivity(forSpeed: speed)
            expect(value > previous, "sensitivity must be monotonically increasing at \(speed)")
            previous = value
        }
        expect(approx(engineForCurve.sensitivity(forSpeed: 7000), tuning.maxSensitivity),
               "sensitivity must reach the cap")
        expect(approx(engineForCurve.sensitivity(forSpeed: 99_999), tuning.maxSensitivity),
               "sensitivity must stay capped")

        // MARK: Direction

        func makeEngine(base: Double = 100, duration: Double = 200) -> ScrubEngine {
            var engine = ScrubEngine()
            engine.begin(x: 0, timestamp: 0, basePosition: base, duration: duration)
            return engine
        }

        var right = makeEngine()
        let rightResult = right.update(x: 20, timestamp: 0.1)
        expect(rightResult.delta < 0, "dragging right must rewind")
        expect(rightResult.angleDelta < 0, "dragging right must rotate counter-clockwise")
        expect(rightResult.position < 100, "rewind must move the position backwards")

        var left = makeEngine()
        let leftResult = left.update(x: -20, timestamp: 0.1)
        expect(leftResult.delta > 0, "dragging left must advance")
        expect(leftResult.angleDelta > 0, "dragging left must rotate clockwise")

        // MARK: Reversal

        var reversal = makeEngine()
        _ = reversal.update(x: 30, timestamp: 0.1)
        let before = reversal.accumulated
        let reversed = reversal.update(x: 20, timestamp: 0.2)
        expect(reversed.delta > before, "direction reversal must take effect immediately")

        // MARK: Velocity amplification

        var slow = makeEngine()
        let slowResult = slow.update(x: 10, timestamp: 0.5)
        var fast = makeEngine()
        let fastResult = fast.update(x: 10, timestamp: 0.004)
        expect(abs(fastResult.delta) > abs(slowResult.delta) * 2, "fast movement must seek much further")
        expect(abs(slowResult.delta) > 0.0, "slow movement must still seek")

        // MARK: Clamping

        var atStart = makeEngine(base: 0)
        let startResult = atStart.update(x: 100, timestamp: 0.1)
        expect(approx(startResult.delta, 0), "cannot rewind before zero")
        expect(approx(startResult.angleDelta, 0), "the disc must stop at the start of the track")
        expect(startResult.hitStart, "hitting the start must be reported")
        let startReversal = atStart.update(x: 90, timestamp: 0.2)
        expect(startReversal.angleDelta > 0, "the disc must rotate again after reversing")
        expect(startReversal.delta > 0, "reversing at zero must advance immediately")

        var atEnd = makeEngine(base: 199.5, duration: 200)
        let endResult = atEnd.update(x: -100, timestamp: 0.1)
        expect(approx(endResult.position, 199.85), "seeking must stop just before the end")
        expect(endResult.hitEnd, "hitting the end must be reported")

        // MARK: Wiggle cancel

        var wiggle = WiggleDetector()
        var wiggleTriggered = false
        var wiggleX: Double = 0
        for i in 1...6 {
            wiggleX = (i % 2 == 1) ? 10 : 0
            if wiggle.update(x: wiggleX, timestamp: Double(i) * 0.1) {
                wiggleTriggered = true
            }
        }
        expect(wiggleTriggered, "a left-right wiggle must be detected")

        var jitter = WiggleDetector()
        var jitterTriggered = false
        for i in 1...10 {
            let x: Double = (i % 2 == 1) ? 2 : 0
            if jitter.update(x: x, timestamp: Double(i) * 0.05) {
                jitterTriggered = true
            }
        }
        expect(!jitterTriggered, "tiny jitter must not cancel a seek")

        var slowWiggle = WiggleDetector()
        var slowTriggered = false
        for i in 1...8 {
            let x: Double = (i % 2 == 1) ? 20 : 0
            if slowWiggle.update(x: x, timestamp: Double(i) * 0.4) {
                slowTriggered = true
            }
        }
        expect(!slowTriggered, "slow alternating strokes outside the window must not cancel")

        let natural = ScrollDirection.physical(deltaX: 10, deltaY: -10, invertedFromDevice: true, precise: true)
        let traditional = ScrollDirection.physical(deltaX: -10, deltaY: 10, invertedFromDevice: false, precise: true)
        expect(natural.right > 0, "natural scrolling: rightward gesture scrubs right")
        expect(traditional.right > 0, "traditional scrolling maps the opposite horizontal sign")
        expect(natural.pull == traditional.pull, "both scrolling preferences must produce the same vertical pull")
        expect(natural.pull < 0, "the vertical direction is inverted relative to the first implementation")

        // MARK: Confirm meter

        var slowMeter = ConfirmAccumulator()
        slowMeter.begin(extra: 0, timestamp: 0, distance: 240)
        for step in 1...3 {
            _ = slowMeter.update(extra: CGFloat(step * 40), timestamp: Double(step) * 0.5)
        }
        expect(!slowMeter.isComplete, "a slow 120 pt pull must not fill a 240 pt meter")
        expect(slowMeter.progress > 0.45 && slowMeter.progress < 0.6,
               "slow pull progress should track raw distance")

        var fastMeter = ConfirmAccumulator()
        fastMeter.begin(extra: 0, timestamp: 0, distance: 240)
        for step in 1...3 {
            _ = fastMeter.update(extra: CGFloat(step * 40), timestamp: Double(step) * 0.02)
        }
        expect(fastMeter.isComplete, "a fast 120 pt pull must fill the meter via acceleration")
        expect(fastMeter.progress > slowMeter.progress, "faster pulls must fill the meter faster")

        var backingOff = ConfirmAccumulator()
        backingOff.begin(extra: 0, timestamp: 0, distance: 240)
        _ = backingOff.update(extra: 120, timestamp: 0.6)
        let high = backingOff.progress
        _ = backingOff.update(extra: 60, timestamp: 1.2)
        expect(backingOff.progress < high, "moving back up must reduce the confirm meter")

        let meter = ConfirmAccumulator()
        expect(meter.accelerationFactor(forSpeed: 200) < 1.2, "slow pulls stay near 1x")
        expect(meter.accelerationFactor(forSpeed: 1800) > 3.0, "fast pulls approach 3.2x")

        // MARK: Layout

        let layout = VinylLayout(notchWidth: 179, capHeight: 32, emergenceInset: 32)
        expect(layout.exposure(forPullDistance: 0) == 0, "no pull, no exposure")
        expect(layout.exposure(forPullDistance: -20) == 0, "negative pull cannot expose the disc")
        var lastExposure: CGFloat = -1
        var monotonic = true
        for step in stride(from: 0.0, through: 200.0, by: 5.0) {
            let exposure = layout.exposure(forPullDistance: CGFloat(step))
            if exposure < lastExposure { monotonic = false }
            lastExposure = exposure
        }
        expect(monotonic, "exposure must increase with pull distance")
        expect(layout.exposure(forPullDistance: 1000) == layout.maxExposure, "exposure must be capped")
        expect(layout.fullExposure >= 80 && layout.fullExposure <= 110,
               "full exposure must be in the 80–110 range")
        expect(approx(layout.recordCenterY(exposure: layout.fullExposure), layout.emergenceInset),
               "the fully extracted record centre must sit on the notch edge")
        let detentExposure = layout.exposure(forPullDistance: layout.grabDetent)
        expect(detentExposure > 30 && detentExposure < layout.fullExposure * 0.6,
               "the magnetic detent must sit around halfway")
        expect(layout.recordCenterY(exposure: 0) < layout.recordCenterY(exposure: layout.fullExposure),
               "the record must move down as it is pulled out")

        let flat = VinylLayout(notchWidth: 179, capHeight: 0, emergenceInset: 0)
        expect(approx(flat.recordCenterY(exposure: flat.fullExposure), 0),
               "on a display without a notch the centre must sit on the screen's top edge")

        // MARK: Music read parsing

        let delimiter = "\u{1F}"
        let raw = ["playing", "95432", "ABC123", "Blue in Green", "Miles Davis", "Kind of Blue", "337000"]
            .joined(separator: delimiter)
        switch AppleMusicBridge.parse(raw) {
        case .success(.track(let state, let position, let id, let title, let artist, let album, let duration)):
            expect(state == "playing", "state parse")
            expect(position == 95432, "position parse")
            expect(id == "ABC123", "id parse")
            expect(title == "Blue in Green", "title parse")
            expect(artist == "Miles Davis", "artist parse")
            expect(album == "Kind of Blue", "album parse")
            expect(duration == 337000, "duration parse")
        default:
            expect(false, "track read must parse")
        }
        expect((try? AppleMusicBridge.parse("NOTRUNNING").get()) == .notRunning, "not-running parse")
        expect((try? AppleMusicBridge.parse("NOTRACK").get()) == .noTrack, "no-track parse")

        // MARK: Formatter

        expect(TimeOffsetFormatter.string(for: -2.74) == "−2.7s", "negative offset formatting")
        expect(TimeOffsetFormatter.string(for: 3.41) == "+3.4s", "positive offset formatting")
        expect(TimeOffsetFormatter.string(for: 0.01) == "0.0s", "zero offset formatting")
        expect(TimeOffsetFormatter.string(for: 63.4) == "+1:03.4", "minute offset formatting")

        // MARK: Report

        if failures.isEmpty {
            print("SelfChecks: all checks passed")
            return 0
        }
        for failure in failures {
            print("SelfChecks: FAIL — \(failure)")
        }
        print("SelfChecks: \(failures.count) failure(s)")
        return failures.count
    }
}
