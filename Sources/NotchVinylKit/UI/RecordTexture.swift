import AppKit

/// Offscreen artwork for the record. Rendered once per track (not per frame) so
/// the 60 Hz animation only has to rotate a bitmap.
enum RecordTexture {
    static func make(
        radius: CGFloat,
        labelRadius: CGFloat,
        artwork: NSImage?,
        title: String,
        artist: String,
        scale: CGFloat = 3
    ) -> NSImage? {
        let pointSize = NSSize(width: radius * 2, height: radius * 2)
        let pixels = Int(ceil(pointSize.width * scale))
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
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)

        let fullRect = NSRect(origin: .zero, size: pointSize)
        NSColor.clear.setFill()
        fullRect.fill()

        let center = NSPoint(x: radius, y: radius)

        drawDisc(radius: radius, labelRadius: labelRadius, center: center)
        drawGrooves(radius: radius, labelRadius: labelRadius, center: center)
        drawLabel(
            labelRadius: labelRadius,
            center: center,
            artwork: artwork,
            title: title,
            artist: artist
        )
        drawSpindle(center: center, labelRadius: labelRadius)
        drawRim(radius: radius, center: center)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    private static func drawDisc(radius: CGFloat, labelRadius: CGFloat, center: NSPoint) {
        let rect = NSRect(
            x: center.x - radius + 0.5,
            y: center.y - radius + 0.5,
            width: (radius - 0.5) * 2,
            height: (radius - 0.5) * 2
        )
        VinylTheme.recordBaseNS.setFill()
        NSBezierPath(ovalIn: rect).fill()

        // A faint warm bounce so the black disc still reads against black.
        let glow = NSGradient(
            starting: NSColor(white: 1, alpha: 0.035),
            ending: NSColor(white: 1, alpha: 0)
        )
        glow?.draw(
            in: NSBezierPath(ovalIn: rect),
            relativeCenterPosition: NSPoint(x: -0.25, y: 0.35)
        )
    }

    private static func drawGrooves(radius: CGFloat, labelRadius: CGFloat, center: NSPoint) {
        let inner = labelRadius + 6
        let outer = radius - 4
        let count = 88

        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let r = inner + (outer - inner) * t
            // Groove density has gentle banding, like a real pressing.
            let wave = 0.5 + 0.5 * sin(Double(i) * 2.37 + 1.2)
            let alpha = 0.016 + 0.043 * wave
            NSColor(white: 1, alpha: alpha).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(
                x: center.x - r,
                y: center.y - r,
                width: r * 2,
                height: r * 2
            ))
            path.lineWidth = 0.34
            path.stroke()
        }

        // Track bands: a few slightly wider, darker grooves.
        for r in [inner + 18, inner + 34, inner + 48, inner + 62] where r < outer {
            NSColor(white: 0, alpha: 0.35).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(
                x: center.x - r,
                y: center.y - r,
                width: r * 2,
                height: r * 2
            ))
            path.lineWidth = 0.8
            path.stroke()
        }

        // Two faint radial marks sell the rotation of an otherwise symmetric disc.
        drawRadialMark(from: inner + 4, to: outer - 2, angleDegrees: 36, center: center, alpha: 0.055)
        drawRadialMark(from: labelRadius + 22, to: outer - 6, angleDegrees: 214, center: center, alpha: 0.035)
    }

    private static func drawRadialMark(
        from inner: CGFloat,
        to outer: CGFloat,
        angleDegrees: Double,
        center: NSPoint,
        alpha: CGFloat
    ) {
        let a = angleDegrees * .pi / 180
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
        path.line(to: NSPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
        path.lineWidth = 0.5
        NSColor(white: 1, alpha: alpha).setStroke()
        path.stroke()
    }

    private static func drawLabel(
        labelRadius: CGFloat,
        center: NSPoint,
        artwork: NSImage?,
        title: String,
        artist: String
    ) {
        let rect = NSRect(
            x: center.x - labelRadius,
            y: center.y - labelRadius,
            width: labelRadius * 2,
            height: labelRadius * 2
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()

        if let artwork, artwork.size.width > 1, artwork.size.height > 1 {
            drawAspectFill(artwork, in: rect)
            NSColor(white: 0, alpha: 0.08).setFill()
            rect.fill()
        } else {
            drawPaperLabel(in: rect, title: title, artist: artist)
        }

        NSGraphicsContext.restoreGraphicsState()

        // The edge of the label, and a tiny shadow where it meets the vinyl.
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.35, dy: 0.35))
        edge.lineWidth = 0.7
        NSColor(white: 0, alpha: 0.55).setStroke()
        edge.stroke()

        if artwork == nil {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.2, dy: 2.2))
            ring.lineWidth = 0.4
            NSColor(white: 1, alpha: 0.18).setStroke()
            ring.stroke()
        }
    }

    private static func drawPaperLabel(in rect: NSRect, title: String, artist: String) {
        let accent = VinylTheme.accent(for: artist + "|" + title)
        accent.setFill()
        rect.fill()

        // Slightly lighter wash at the top-left, like printed paper.
        let wash = NSGradient(
            starting: NSColor(white: 1, alpha: 0.10),
            ending: NSColor(white: 1, alpha: 0)
        )
        wash?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))

        let ink = contrastingInk(for: accent)
        let center = NSPoint(x: rect.midX, y: rect.midY)

        let initials = initialsFor(title: title, artist: artist)
        drawCentered(
            initials,
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: ink,
            tracking: 0.6,
            centerX: center.x,
            y: center.y + 5.4
        )

        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: center.x - 8, y: center.y - 2.4))
        rule.line(to: NSPoint(x: center.x + 8, y: center.y - 2.4))
        rule.lineWidth = 0.5
        ink.withAlphaComponent(0.55).setStroke()
        rule.stroke()

        drawCentered(
            "33⅓",
            font: .systemFont(ofSize: 4.6, weight: .medium),
            color: ink.withAlphaComponent(0.8),
            tracking: 0.5,
            centerX: center.x,
            y: center.y - 7.6
        )
    }

    private static func drawSpindle(center: NSPoint, labelRadius: CGFloat) {
        let holeRadius: CGFloat = 2.15
        let hole = NSRect(
            x: center.x - holeRadius,
            y: center.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        )
        VinylTheme.recordBaseNS.setFill()
        NSBezierPath(ovalIn: hole).fill()
        NSColor(white: 1, alpha: 0.22).setStroke()
        let rim = NSBezierPath(ovalIn: hole)
        rim.lineWidth = 0.4
        rim.stroke()

        // A pinprick of light in the spindle keeps the centre from going flat.
        NSColor(white: 1, alpha: 0.30).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - 0.55,
            y: center.y + 0.25,
            width: 1.1,
            height: 1.1
        )).fill()
    }

    private static func drawRim(radius: CGFloat, center: NSPoint) {
        let r = radius - 0.9
        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - r,
            y: center.y - r,
            width: r * 2,
            height: r * 2
        ))
        path.lineWidth = 0.75
        NSColor(white: 1, alpha: 0.14).setStroke()
        path.stroke()
    }

    private static func drawCentered(
        _ text: String,
        font: NSFont,
        color: NSColor,
        tracking: CGFloat,
        centerX: CGFloat,
        y: CGFloat
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: tracking,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: centerX - size.width / 2, y: y))
    }

    private static func drawAspectFill(_ image: NSImage, in rect: NSRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let factor = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * factor, height: imageSize.height * factor)
        let drawRect = NSRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func initialsFor(title: String, artist: String) -> String {
        let source = artist.isEmpty ? title : artist
        let words = source
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "&" })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        let result = letters.joined().uppercased()
        return result.isEmpty ? "NV" : result
    }

    private static func contrastingInk(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return VinylTheme.labelCream }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.58 ? VinylTheme.labelInk : VinylTheme.labelCream
    }
}
