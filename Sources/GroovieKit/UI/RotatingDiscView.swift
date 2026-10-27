import AppKit
import SwiftUI

/// The rotating surface of the record, backed by a CALayer.
///
/// Playback rotation is a Core Animation animation running on the render
/// server, so a record left out while music plays does not drive SwiftUI's
/// view graph every frame. Only a scrub (where the angle follows the pointer)
/// updates the view, and the spin/coast/stop transitions are driven by the
/// controller's `DiscSpin` changes. Starting the animations on the reference's
/// clock keeps the layer and the controller on the same angle.
struct RotatingDiscView: NSViewRepresentable {
    let image: NSImage?
    let size: CGFloat
    let angle: Double
    let spin: DiscSpin
    let degreesPerSecond: Double

    func makeNSView(context: Context) -> DiscLayerView {
        let view = DiscLayerView()
        view.setFrameSize(NSSize(width: size, height: size))
        return view
    }

    func updateNSView(_ view: DiscLayerView, context: Context) {
        view.update(
            image: image,
            angle: angle,
            spin: spin,
            degreesPerSecond: degreesPerSecond
        )
    }
}

final class DiscLayerView: NSView {
    private let spinner = CALayer()
    private var textureIdentity: ObjectIdentifier?

    /// The incoming cover fading in over the old one. It is a child of
    /// `spinner`, so it inherits the record's rotation exactly and a track
    /// change never has to align two separately animated discs.
    private var fadeLayer: CALayer?
    private let crossFadeDuration: CFTimeInterval = 0.42

    private let rotationKey = "com.groovie.disc.spin"
    private let spinUpKey = "com.groovie.disc.spinUp"
    private let coastKey = "com.groovie.disc.coast"
    private var spinUpToken: CFTimeInterval?
    private var coastToken: CFTimeInterval?

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
        fadeLayer?.frame = spinner.bounds
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
    }

    func update(
        image: NSImage?,
        angle: Double,
        spin: DiscSpin,
        degreesPerSecond: Double
    ) {
        updateImage(image)
        updateRotation(angle: angle, spin: spin, degreesPerSecond: degreesPerSecond)
    }

    // MARK: - Texture

    private func updateImage(_ image: NSImage?) {
        let identity = image.map(ObjectIdentifier.init)
        guard identity != textureIdentity else { return }

        guard let image else {
            textureIdentity = identity
            finishFade()
            spinner.contents = nil
            return
        }

        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return
        }

        let hadTexture = textureIdentity != nil && spinner.contents != nil
        textureIdentity = identity
        let scale = window?.backingScaleFactor ?? 2

        // The first texture has nothing to cross-fade from; every later one
        // (the next track, a new skin, a cover arriving after its label)
        // dissolves in so the record never flashes an empty label between songs.
        guard hadTexture else {
            spinner.contents = cgImage
            spinner.contentsScale = scale
            return
        }

        crossFade(to: cgImage, scale: scale)
    }

    private func crossFade(to cgImage: CGImage, scale: CGFloat) {
        // If a fade is still in flight, the disc is already partly showing its
        // target. Promote that first so the next fade starts from what the eye
        // can actually see.
        finishFade()

        let incoming = CALayer()
        incoming.contents = cgImage
        incoming.contentsGravity = .resize
        incoming.minificationFilter = .trilinear
        incoming.magnificationFilter = .trilinear
        incoming.allowsEdgeAntialiasing = true
        incoming.contentsScale = scale
        incoming.opacity = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.frame = spinner.bounds
        spinner.addSublayer(incoming)
        CATransaction.commit()

        fadeLayer = incoming

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = crossFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak incoming] in
            // The incoming layer is already opaque on screen, so promoting it
            // one run-loop turn late cannot flash. Doing it on the main queue
            // keeps the Core Animation callback off the actor boundary.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let incoming, self.fadeLayer === incoming else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.spinner.contents = incoming.contents
                    incoming.removeFromSuperlayer()
                    CATransaction.commit()
                    self.fadeLayer = nil
                }
            }
        }
        incoming.opacity = 1
        incoming.add(fade, forKey: "crossfade")
        CATransaction.commit()
    }

    /// Finish a fade early, keeping whatever it was revealing.
    private func finishFade() {
        guard let fade = fadeLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.contents = fade.contents
        fade.removeFromSuperlayer()
        CATransaction.commit()
        fadeLayer = nil
    }

    // MARK: - Rotation

    private func updateRotation(angle: Double, spin: DiscSpin, degreesPerSecond: Double) {
        let rot = spinner.animation(forKey: rotationKey) != nil
        let up = spinner.animation(forKey: spinUpKey) != nil
        let coast = spinner.animation(forKey: coastKey) != nil
        Diag.log("layer \(spin.diagName) rot=\(rot) up=\(up) coast=\(coast) inWindow=\(window != nil)")
        switch spin {
        case .spinningUp(let up):
            coastToken = nil
            if spinUpToken == up.since, spinner.animation(forKey: spinUpKey) != nil {
                return
            }
            spinner.removeAnimation(forKey: rotationKey)
            spinner.removeAnimation(forKey: coastKey)
            spinUpToken = up.since
            applySpinUp(up, degreesPerSecond: degreesPerSecond)

        case .spinning(let reference):
            coastToken = nil
            spinUpToken = nil
            spinner.removeAnimation(forKey: coastKey)
            spinner.removeAnimation(forKey: spinUpKey)
            // Keep the animation that is already running: restarting it on every
            // state change would jump the record back to the sampled angle.
            guard spinner.animation(forKey: rotationKey) == nil else { return }

            // SwiftUI's positive rotation reads clockwise; the layer tree is
            // y-up, where a positive z rotation reads counter-clockwise.
            let from = -reference.angle * .pi / 180
            setRotation(from)

            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = from
            animation.toValue = from - 2 * .pi
            animation.duration = 360 / max(degreesPerSecond, 1)
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            // Starting on the controller's clock means the angle it computes
            // when the pointer takes over is the angle on screen, even though
            // this layer commits a frame later.
            animation.beginTime = reference.since
            spinner.add(animation, forKey: rotationKey)
            Diag.log("layer added rotation since=\(String(format: "%.2f", reference.since))")

        case .coasting(let down):
            if coastToken == down.since, spinner.animation(forKey: coastKey) != nil {
                return
            }
            spinner.removeAnimation(forKey: rotationKey)
            spinner.removeAnimation(forKey: spinUpKey)
            spinUpToken = nil
            coastToken = down.since
            applyCoast(down)

        case .stopped:
            coastToken = nil
            spinUpToken = nil
            spinner.removeAnimation(forKey: rotationKey)
            spinner.removeAnimation(forKey: spinUpKey)
            spinner.removeAnimation(forKey: coastKey)
            setRotation(-angle * .pi / 180)
        }
    }

    /// How long the launch animation keeps turning after the approach ends, if
    /// the controller has not replaced it yet. The render server runs this
    /// without the app, so a throttled or suspended run loop (App Nap, a
    /// sleeping display) cannot leave the record frozen while music plays.
    private static let spinUpTail: CFTimeInterval = 3_600

    /// Run the platter's spin-up on the render server. Like the brake, it is
    /// sampled from the shared curve so the controller's angle and the layer
    /// agree. The samples cover the exponential approach and then one long
    /// linear segment at playback speed; normally the controller's tick swaps
    /// this for the endless rotation right after the approach, but the tail
    /// keeps the disc turning if that tick is late.
    private func applySpinUp(_ up: SpinUp, degreesPerSecond: Double) {
        let sampleCount = 30
        let total = SpinUpCurve.settleTime + Self.spinUpTail
        var values: [CGFloat] = []
        var keyTimes: [NSNumber] = []
        values.reserveCapacity(sampleCount + 2)
        keyTimes.reserveCapacity(sampleCount + 2)

        for index in 0...sampleCount {
            let elapsed = SpinUpCurve.settleTime * Double(index) / Double(sampleCount)
            let degrees = up.angle + SpinUpCurve.travelled(
                target: degreesPerSecond,
                startSpeed: up.startSpeed,
                elapsed: elapsed
            )
            values.append(CGFloat(-degrees * .pi / 180))
            keyTimes.append(NSNumber(value: elapsed / total))
        }

        // From the end of the approach the curve is linear at target speed, so
        // two points define the whole tail.
        let tailDegrees = up.angle + SpinUpCurve.travelled(
            target: degreesPerSecond,
            startSpeed: up.startSpeed,
            elapsed: total
        )
        values.append(CGFloat(-tailDegrees * .pi / 180))
        keyTimes.append(NSNumber(value: 1.0))

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        animation.duration = total
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        animation.beginTime = up.since

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.transform = CATransform3DMakeRotation(values.last ?? 0, 0, 0, 1)
        CATransaction.commit()
        spinner.add(animation, forKey: spinUpKey)
    }

    /// Run the platter's deceleration on the render server. The curve is
    /// sampled into keyframes so it matches `SpinDownCurve` exactly, and it
    /// starts at the pause instant rather than at commit time.
    private func applyCoast(_ down: SpinDown) {
        let sampleCount = 30
        var values: [CGFloat] = []
        values.reserveCapacity(sampleCount + 1)
        for index in 0...sampleCount {
            let elapsed = SpinDownCurve.settleTime * Double(index) / Double(sampleCount)
            let degrees = down.angle
                + SpinDownCurve.travelled(startSpeed: down.speed, elapsed: elapsed)
            values.append(CGFloat(-degrees * .pi / 180))
        }

        let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        animation.values = values
        animation.duration = SpinDownCurve.settleTime
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        animation.beginTime = down.since

        // Park the model transform on the resting angle too, so removing the
        // animation later (a grab, a resume) does not put the disc back where
        // the coast started.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.transform = CATransform3DMakeRotation(values.last ?? 0, 0, 0, 1)
        CATransaction.commit()
        spinner.add(animation, forKey: coastKey)
    }

    private func setRotation(_ radians: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
        CATransaction.commit()
    }
}
