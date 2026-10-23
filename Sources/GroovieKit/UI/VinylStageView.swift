import SwiftUI

struct VinylStageView: View {
    @ObservedObject var model: VinylViewModel
    let hover: RecordHoverModel
    let layout: VinylLayout

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = layout.recordCenter(in: size, exposure: model.exposure)

            ZStack(alignment: .topLeading) {
                // The record is rendered as a plain full circle. Nothing is drawn
                // over it: on a notched Mac the hardware covers the upper half,
                // and on a display without one the screen's top edge clips it. The
                // stage also clips the circle, so screenshots show the disc as-is.
                VinylDiscView(
                    radius: layout.recordRadius,
                    labelRadius: layout.labelRadius,
                    angle: model.angle,
                    isSpinning: model.isSpinning,
                    degreesPerSecond: layout.playbackDegreesPerSecond,
                    title: model.trackTitle,
                    artist: model.trackArtist,
                    artwork: model.artwork,
                    skin: model.skin
                )
                .position(center)

                RecordHoverOverlay(
                    hover: hover,
                    layout: layout,
                    center: center,
                    isPlaying: model.isPlaying
                )
                hud(center: center)
                confirmGauge(size: size)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    /// Semi-transparent "pull further to lock" meter shown below the record while
    /// it is out but has not been confirmed yet.
    @ViewBuilder
    private func confirmGauge(size: CGSize) -> some View {
        let progress = CGFloat(min(max(model.confirmProgress, 0), 1))
        let width: CGFloat = 128
        VStack(spacing: 4) {
            Text(verbatim: L10n.t(.overlayPullToLock))
                .font(.system(size: 8, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.40))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(.white.opacity(0.58))
                    .frame(width: max(0, width * progress))
            }
            .frame(width: width, height: 3.5)
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(.black.opacity(0.22))
        )
        .opacity(model.showConfirmGauge ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: model.showConfirmGauge)
        .position(
            x: size.width / 2,
            y: layout.emergenceInset + layout.recordRadius + 34
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hud(center: CGPoint) -> some View {
        if model.showTitle {
            VStack(spacing: 3) {
                Text(titleLine)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.15)
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if model.showOffset {
                    Text(TimeOffsetFormatter.string(for: model.offsetSeconds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            .frame(width: layout.recordRadius * 1.55)
            .shadow(color: .black.opacity(0.72), radius: 2.5, x: 0, y: 1)
            .position(x: center.x, y: center.y + layout.recordRadius * 0.80)
            .animation(.easeOut(duration: 0.14), value: model.showOffset)
        }
    }

    private var titleLine: String {
        let title = model.trackTitle.isEmpty ? "Groovie" : model.trackTitle
        let artist = model.trackArtist
        return artist.isEmpty ? title : "\(title) · \(artist)"
    }
}

/// Hover feedback on the pinned record. Only the centre label reacts: it dims
/// while it is the play/pause target, and a faint transport glyph previews what
/// a click will do. The vinyl itself stays still so the disc does not flicker as
/// the pointer crosses it. The effect is clipped by the stage, so only the
/// visible half reacts.
///
/// The overlay is drawn by a CALayer so the fade runs on the render server.
/// A SwiftUI opacity animation here re-evaluated the overlay every frame while
/// the pointer crossed the label edge, which showed up as a CPU spike even
/// though the visual change is tiny.
///
/// This view observes the hover model directly so pointer movement redraws only
/// this small overlay, not the disc and the rest of the stage.
private struct RecordHoverOverlay: View {
    @ObservedObject var hover: RecordHoverModel
    let layout: VinylLayout
    let center: CGPoint
    let isPlaying: Bool

    var body: some View {
        HoverLayerRepresentable(
            hovered: hover.region == .label,
            isPlaying: isPlaying,
            diameter: layout.labelRadius * 2,
            glyphOffset: layout.labelRadius * 0.40
        )
        .frame(width: layout.labelRadius * 2, height: layout.labelRadius * 2)
        .position(center)
        .allowsHitTesting(false)
    }
}

private struct HoverLayerRepresentable: NSViewRepresentable {
    let hovered: Bool
    let isPlaying: Bool
    let diameter: CGFloat
    let glyphOffset: CGFloat

    func makeNSView(context: Context) -> HoverLayerView {
        let view = HoverLayerView()
        view.update(
            hovered: hovered,
            isPlaying: isPlaying,
            diameter: diameter,
            glyphOffset: glyphOffset,
            animated: false
        )
        return view
    }

    func updateNSView(_ view: HoverLayerView, context: Context) {
        view.update(
            hovered: hovered,
            isPlaying: isPlaying,
            diameter: diameter,
            glyphOffset: glyphOffset,
            animated: true
        )
    }
}

/// Clears the hover glyph bitmaps when the overlay is disabled.
func purgeHoverLayerCaches() {
    HoverLayerView.purgeCache()
}

private final class HoverLayerView: NSView {
    /// Only play/pause × one geometry are ever needed; the stage is recreated
    /// every time the record is pulled out, so keep the rendered images.
    private static let imageCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 2
        return cache
    }()

    static func purgeCache() {
        imageCache.removeAllObjects()
    }

    private let overlay = CALayer()
    private var imageKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        overlay.opacity = 0
        overlay.contentsGravity = .resize
        overlay.isOpaque = false
        layer?.addSublayer(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    // The overlay is feedback only; clicks stay on the panel below it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = bounds
        CATransaction.commit()
    }

    func update(
        hovered: Bool,
        isPlaying: Bool,
        diameter: CGFloat,
        glyphOffset: CGFloat,
        animated: Bool
    ) {
        let key = "\(isPlaying)|\(diameter)|\(glyphOffset)"
        if key != imageKey {
            imageKey = key
            if let cached = Self.imageCache.object(forKey: key as NSString) {
                overlay.contents = cached
            } else {
                let image = Self.makeImage(
                    isPlaying: isPlaying,
                    diameter: diameter,
                    glyphOffset: glyphOffset
                )
                if let image {
                    Self.imageCache.setObject(image, forKey: key as NSString)
                }
                overlay.contents = image
            }
        }

        let target: Float = hovered ? 1 : 0
        guard overlay.opacity != target else { return }
        guard animated else {
            overlay.removeAnimation(forKey: "hover")
            overlay.opacity = target
            return
        }

        // Continue from the value on screen so a quick reversal does not jump.
        let from = overlay.presentation()?.opacity ?? overlay.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        overlay.opacity = target
        overlay.add(animation, forKey: "hover")
    }

    private static func makeImage(
        isPlaying: Bool,
        diameter: CGFloat,
        glyphOffset: CGFloat
    ) -> CGImage? {
        let scale: CGFloat = 3
        let pixels = Int(ceil(diameter * scale))
        guard pixels > 8,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: diameter, height: diameter)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.cgContext.scaleBy(x: scale, y: scale)

        // A new bitmap's pixels are not guaranteed to be transparent; clear
        // the square first so only the circle is visible over the label.
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: diameter, height: diameter).fill()

        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: 0,
            y: 0,
            width: diameter,
            height: diameter
        )).fill()

        if let symbol = tintedSymbol(isPlaying: isPlaying) {
            let size = symbol.size
            // The label's centre sits on the notch edge, so the glyph is
            // nudged into the half that stays visible below it. AppKit's
            // canvas is y-up, so "down" is negative.
            let rect = NSRect(
                x: (diameter - size.width) / 2 + (isPlaying ? 0 : 0.6),
                y: (diameter - size.height) / 2 - glyphOffset,
                width: size.width,
                height: size.height
            )

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Tint the template symbol in its own transparent bitmap. Filling the
    /// symbol's rect with `sourceAtop` directly on the overlay would also paint
    /// over the dark disc behind it, leaving a light rectangle around the glyph.
    private static func tintedSymbol(isPlaying: Bool) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        ) else { return nil }

        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return nil }

        // Render at the same 3x scale as the overlay; drawing a 1x image into
        // the 3x context would soften the glyph.
        let scale: CGFloat = 3
        let pixelsWide = Int(ceil(size.width * scale))
        let pixelsHigh = Int(ceil(size.height * scale))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        symbol.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.withAlphaComponent(0.72).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: size)
        output.addRepresentation(rep)
        return output
    }
}

enum TimeOffsetFormatter {
    /// `−2.7s`, `+3.4s`, or `+1:03.4` for larger jumps.
    static func string(for seconds: Double) -> String {
        let magnitude = abs(seconds)
        if magnitude < 0.05 {
            return "0.0s"
        }
        let sign = seconds < 0 ? "−" : "+"
        if magnitude < 60 {
            return sign + String(format: "%.1fs", magnitude)
        }
        let minutes = Int(magnitude) / 60
        let remainder = magnitude - Double(minutes * 60)
        return sign + String(format: "%d:%04.1f", minutes, remainder)
    }
}
