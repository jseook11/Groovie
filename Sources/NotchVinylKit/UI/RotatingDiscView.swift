import AppKit
import SwiftUI

/// The rotating surface of the record, backed by a CALayer.
///
/// Playback rotation is a Core Animation animation running on the render
/// server, so a record left out while music plays does not drive SwiftUI's
/// view graph every frame. Only a scrub (where the angle follows the pointer)
/// updates the view, and the freeze/spin transitions are driven by the
/// controller's phase changes.
struct RotatingDiscView: NSViewRepresentable {
    let image: NSImage?
    let size: CGFloat
    let angle: Double
    let isSpinning: Bool
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
            isSpinning: isSpinning,
            degreesPerSecond: degreesPerSecond
        )
    }
}

final class DiscLayerView: NSView {
    private let spinner = CALayer()
    private var textureIdentity: ObjectIdentifier?
    private let rotationKey = "com.notchvinyl.disc.spin"

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

    func update(image: NSImage?, angle: Double, isSpinning: Bool, degreesPerSecond: Double) {
        updateImage(image)

        // SwiftUI's positive rotation reads clockwise; the layer tree is y-up,
        // where a positive z rotation reads counter-clockwise.
        let radians = -angle * .pi / 180

        if isSpinning {
            // Keep the animation that is already running: restarting it on every
            // state change would jump the record back to the sampled angle.
            guard spinner.animation(forKey: rotationKey) == nil else { return }
            setRotation(radians)

            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = radians
            animation.toValue = radians - 2 * .pi
            animation.duration = 360 / max(degreesPerSecond, 1)
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            spinner.add(animation, forKey: rotationKey)
        } else {
            spinner.removeAnimation(forKey: rotationKey)
            setRotation(radians)
        }
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

    private func setRotation(_ radians: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
        CATransaction.commit()
    }
}
