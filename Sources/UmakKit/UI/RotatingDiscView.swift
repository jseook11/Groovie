import AppKit
import SwiftUI

/// The rotating surface of the record, backed by a CALayer.
///
/// Playback rotation is a Core Animation animation running on the render
/// server, so a record left out while music plays does not drive SwiftUI's
/// view graph every frame. The run-up and brake are keyframe animations built
/// from the same `SpinMotion` the controller samples, so taking the angle with
/// the pointer mid-transition never jumps.
struct RotatingDiscView: NSViewRepresentable {
    let image: NSImage?
    let size: CGFloat
    let angle: Double
    let spin: SpinMotion

    func makeNSView(context: Context) -> DiscLayerView {
        let view = DiscLayerView()
        view.setFrameSize(NSSize(width: size, height: size))
        return view
    }

    func updateNSView(_ view: DiscLayerView, context: Context) {
        view.update(image: image, angle: angle, spin: spin)
    }
}

final class DiscLayerView: NSView {
    private let spinner = CALayer()
    private var textureIdentity: ObjectIdentifier?
    private let rampKey = "com.umak.disc.ramp"
    private let steadyKey = "com.umak.disc.steady"
    /// The motion already handed to the layer. Unrelated SwiftUI updates must
    /// not restart an animation that is in flight.
    private var appliedSpin: SpinMotion?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let host = layer else { return }

        spinner.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spinner.contentsGravity = .resize
        spinner.minificationFilter = .trilinear
        spinner.magnificationFilter = .trilinear
        spinner.allowsEdgeAntialiasing = true
        host.addSublayer(spinner)

        // The shadow lives on the non-rotating container with a fixed circular
        // path. On the spinning layer its offset would rotate with the record.
        host.shadowColor = NSColor.black.cgColor
        host.shadowOpacity = 0.45
        host.shadowRadius = 10
        host.shadowOffset = CGSize(width: 0, height: -5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.bounds = CGRect(origin: .zero, size: bounds.size)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    func update(image: NSImage?, angle: Double, spin: SpinMotion) {
        updateImage(image)

        // When playback is off the pointer owns the angle, which changes while
        // scrubbing even though the motion does not.
        guard spin.isRotating else {
            appliedSpin = .stopped
            clearSpinAnimations()
            setRotation(radians(angle))
            return
        }

        guard spin != appliedSpin else { return }
        appliedSpin = spin
        clearSpinAnimations()

        switch spin {
        case .stopped:
            break

        case let .starting(_, _, topSpeed, startTime, duration):
            let rampEnd = spin.angle(at: startTime + duration)
            setRotation(radians(rampEnd))
            addRamp(spin, startTime: startTime, duration: duration)
            // Hand the end of the run-up straight to the steady spin so the
            // render server crosses the boundary without a controller tick.
            addSteady(fromAngle: rampEnd, speed: topSpeed, beginTime: startTime + duration)

        case let .steady(fromAngle, speed, startTime):
            setRotation(radians(fromAngle))
            addSteady(fromAngle: fromAngle, speed: speed, beginTime: startTime)

        case let .stopping(_, _, startTime, duration):
            setRotation(radians(spin.angle(at: startTime + duration)))
            addRamp(spin, startTime: startTime, duration: duration)
        }
    }

    /// Sample the shared curve at video rate. Linear keyframes between those
    /// samples are indistinguishable from the analytic curve.
    private func addRamp(_ spin: SpinMotion, startTime: CFTimeInterval, duration: Double) {
        let steps = max(2, Int((duration * 60).rounded(.up)))
        var values: [Double] = []
        var keyTimes: [NSNumber] = []
        values.reserveCapacity(steps + 1)
        keyTimes.reserveCapacity(steps + 1)

        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            values.append(radians(spin.angle(at: startTime + duration * progress)))
            keyTimes.append(NSNumber(value: progress))
        }

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.keyTimes = keyTimes
        // The controller's clock is the host clock, so a late update starts
        // the curve where it should be rather than at the beginning.
        animation.beginTime = startTime
        animation.duration = duration
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        spinner.add(animation, forKey: rampKey)
    }

    private func addSteady(
        fromAngle: Double,
        speed: Double,
        beginTime: CFTimeInterval
    ) {
        let from = radians(fromAngle)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = from
        animation.toValue = from - 2 * .pi
        animation.duration = 360 / max(speed, 1)
        animation.beginTime = beginTime
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        spinner.add(animation, forKey: steadyKey)
    }

    private func clearSpinAnimations() {
        spinner.removeAnimation(forKey: rampKey)
        spinner.removeAnimation(forKey: steadyKey)
    }

    private func updateImage(_ image: NSImage?) {
        let identity = image.map(ObjectIdentifier.init)
        guard identity != textureIdentity else { return }
        textureIdentity = identity
        guard let image else {
            spinner.contents = nil
            return
        }
        var rect = CGRect(origin: .zero, size: image.size)
        spinner.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        spinner.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// SwiftUI's positive rotation reads clockwise; the layer tree is y-up,
    /// where a positive z rotation reads counter-clockwise.
    private func radians(_ angle: Double) -> Double {
        -angle * .pi / 180
    }

    private func setRotation(_ radians: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
        CATransaction.commit()
    }
}
