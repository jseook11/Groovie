import AppKit

/// Offscreen artwork for the record. Rendered once per track/skin (not per
/// frame) so the 60 Hz animation only has to rotate a bitmap.
enum RecordTexture {
    /// Rendering a full disc costs around 10 ms, and the stage is recreated
    /// every time the record is pulled out. Both the finished texture and the
    /// static vinyl base (disc and grooves, which do not depend on the track)
    /// are cached so only a genuinely new track pays for drawing.
    private static let textureCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()
    private static let baseCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    /// Identity of a rendered texture. The label only prints the title and
    /// artist when there is no artwork, so those fields must not invalidate a
    /// texture that already contains a cover. That keeps a track change from
    /// drawing the previous cover again while the new artwork is fetched.
    static func textureKey(
        radius: CGFloat,
        labelRadius: CGFloat,
        artwork: NSImage?,
        title: String,
        artist: String,
        skin: VinylSkin,
        scale: CGFloat = 3
    ) -> String {
        let content = artwork.map { "art:\(ObjectIdentifier($0).hashValue)" }
            ?? "paper:\(title)|\(artist)"
        return "\(skin.id)|\(radius)|\(labelRadius)|\(scale)|\(content)"
    }

    static func cachedTexture(for key: String) -> NSImage? {
        textureCache.object(forKey: key as NSString)
    }

    /// Drops rendered textures when the overlay or desktop records are turned
    /// off. The next use pays one render instead of keeping up to 32 MB alive.
    static func purge() {
        textureCache.removeAllObjects()
        baseCache.removeAllObjects()
    }

    static func make(
        radius: CGFloat,
        labelRadius: CGFloat,
        artwork: NSImage?,
        title: String,
        artist: String,
        skin: VinylSkin = .classic,
        scale: CGFloat = 3
    ) -> NSImage? {
        let key = textureKey(
            radius: radius,
            labelRadius: labelRadius,
            artwork: artwork,
            title: title,
            artist: artist,
            skin: skin,
            scale: scale
        )
        if let cached = textureCache.object(forKey: key as NSString) {
            return cached
        }

        let pointSize = NSSize(width: radius * 2, height: radius * 2)
        guard let (rep, ctx) = makeBitmap(pointSize: pointSize, scale: scale) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)

        let fullRect = NSRect(origin: .zero, size: pointSize)
        NSColor.clear.setFill()
        fullRect.fill()

        let center = NSPoint(x: radius, y: radius)

        // The disc and its grooves depend only on the skin and size, so they
        // are rendered once and composited under each track's label.
        if let base = vinylBase(
            radius: radius,
            labelRadius: labelRadius,
            skin: skin,
            scale: scale
        ) {
            base.draw(
                in: fullRect,
                from: NSRect(origin: .zero, size: base.size),
                operation: .sourceOver,
                fraction: 1
            )
        } else {
            drawDisc(radius: radius, center: center, skin: skin)
            drawGrooves(radius: radius, labelRadius: labelRadius, center: center, skin: skin)
        }
        drawLabel(
            labelRadius: labelRadius,
            center: center,
            artwork: artwork,
            title: title,
            artist: artist,
            skin: skin
        )
        drawSpindle(center: center, skin: skin)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        textureCache.setObject(
            image,
            forKey: key as NSString,
            cost: cacheCost(pointSize: pointSize, scale: scale)
        )
        return image
    }

    private static func vinylBase(
        radius: CGFloat,
        labelRadius: CGFloat,
        skin: VinylSkin,
        scale: CGFloat
    ) -> NSImage? {
        let key = "\(skin.id)|\(radius)|\(labelRadius)|\(scale)" as NSString
        if let cached = baseCache.object(forKey: key) {
            return cached
        }

        let pointSize = NSSize(width: radius * 2, height: radius * 2)
        guard let (rep, ctx) = makeBitmap(pointSize: pointSize, scale: scale) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)

        let fullRect = NSRect(origin: .zero, size: pointSize)
        NSColor.clear.setFill()
        fullRect.fill()

        let center = NSPoint(x: radius, y: radius)
        drawDisc(radius: radius, center: center, skin: skin)
        drawGrooves(radius: radius, labelRadius: labelRadius, center: center, skin: skin)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        baseCache.setObject(
            image,
            forKey: key,
            cost: cacheCost(pointSize: pointSize, scale: scale)
        )
        return image
    }

    private static func makeBitmap(
        pointSize: NSSize,
        scale: CGFloat
    ) -> (NSBitmapImageRep, NSGraphicsContext)? {
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
        return (rep, ctx)
    }

    private static func cacheCost(pointSize: NSSize, scale: CGFloat) -> Int {
        Int(pointSize.width * scale) * Int(pointSize.height * scale) * 4
    }

    private static func drawDisc(radius: CGFloat, center: NSPoint, skin: VinylSkin) {
        let rect = NSRect(
            x: center.x - radius + 0.5,
            y: center.y - radius + 0.5,
            width: (radius - 0.5) * 2,
            height: (radius - 0.5) * 2
        )
        let circle = NSBezierPath(ovalIn: rect)

        let disc = NSGradient(colorsAndLocations:
            (skin.recordCenter, 0.0),
            (blend(skin.recordCenter, skin.recordEdge, 0.55), 0.55),
            (blend(skin.recordCenter, skin.recordEdge, 0.84), 0.84),
            (skin.recordEdge, 1.0)
        )
        if let disc {
            disc.draw(in: circle, relativeCenterPosition: .zero)
        } else {
            skin.recordCenter.setFill()
            circle.fill()
        }

        // A gentle vignette gives the disc a rounded edge rather than a flat fill.
        let vignette = NSGradient(colorsAndLocations:
            (NSColor(white: 0, alpha: 0), 0.58),
            (NSColor(white: 0, alpha: 0.20), 1.0)
        )
        vignette?.draw(in: circle, relativeCenterPosition: .zero)
    }

    private static func drawGrooves(
        radius: CGFloat,
        labelRadius: CGFloat,
        center: NSPoint,
        skin: VinylSkin
    ) {
        let inner = labelRadius + 7
        let outer = radius - 3.5
        let count = 96
        guard outer > inner else { return }

        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let r = inner + (outer - inner) * t
            // Gentle banding, like a real pressing rather than a metronome.
            let wave = 0.5 + 0.5 * sin(Double(i) * 2.399 + 1.2)
            let nearLabel = 0.76 + 0.24 * (1 - t)
            let alpha = (0.055 + 0.105 * wave) * nearLabel
            strokeRing(
                radius: r,
                center: center,
                color: skin.grooveLight.withAlphaComponent(alpha),
                lineWidth: 0.34
            )
        }

        // A shadow line inside every third groove gives the rings depth.
        for i in stride(from: 0, to: count, by: 3) {
            let t = CGFloat(i) / CGFloat(count - 1)
            let r = inner + (outer - inner) * t - 0.45
            strokeRing(
                radius: r,
                center: center,
                color: skin.grooveDark.withAlphaComponent(0.10),
                lineWidth: 0.5
            )
        }

        // Lead-in rings just inside the rim.
        for r in [radius - 6.5, radius - 5.2, radius - 4.0] where r < outer {
            strokeRing(
                radius: r,
                center: center,
                color: skin.grooveLight.withAlphaComponent(0.12),
                lineWidth: 0.4
            )
        }

        // Run-out: a nearly smooth ring next to the label.
        for r in [labelRadius + 2.8, labelRadius + 4.6] {
            strokeRing(
                radius: r,
                center: center,
                color: skin.grooveLight.withAlphaComponent(0.05),
                lineWidth: 0.4
            )
        }

        // Track bands: a wider dark groove with a catching lip on its outer side.
        for band in 0..<3 {
            let r = inner + (outer - inner) * (0.28 + 0.24 * CGFloat(band))
            strokeRing(
                radius: r,
                center: center,
                color: skin.grooveDark.withAlphaComponent(0.28),
                lineWidth: 1.15
            )
            strokeRing(
                radius: r + 1.1,
                center: center,
                color: skin.grooveLight.withAlphaComponent(0.08),
                lineWidth: 0.45
            )
        }

        // Two faint radial marks sell the rotation of an otherwise symmetric disc.
        drawRadialMark(
            from: inner + 6,
            to: outer - 4,
            angleDegrees: 36,
            center: center,
            color: skin.grooveLight,
            alpha: 0.07
        )
        drawRadialMark(
            from: labelRadius + 22,
            to: outer - 8,
            angleDegrees: 214,
            center: center,
            color: skin.grooveLight,
            alpha: 0.045
        )
    }

    private static func strokeRing(
        radius: CGFloat,
        center: NSPoint,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        color.setStroke()
        let path = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        path.lineWidth = lineWidth
        path.stroke()
    }

    private static func drawRadialMark(
        from inner: CGFloat,
        to outer: CGFloat,
        angleDegrees: Double,
        center: NSPoint,
        color: NSColor,
        alpha: CGFloat
    ) {
        let a = angleDegrees * .pi / 180
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
        path.line(to: NSPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
        path.lineWidth = 0.5
        color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private static func drawLabel(
        labelRadius: CGFloat,
        center: NSPoint,
        artwork: NSImage?,
        title: String,
        artist: String,
        skin: VinylSkin
    ) {
        let rect = NSRect(
            x: center.x - labelRadius,
            y: center.y - labelRadius,
            width: labelRadius * 2,
            height: labelRadius * 2
        )

        // A faint contact ring on the vinyl where the label meets the surface.
        strokeRing(
            radius: labelRadius + 1.3,
            center: center,
            color: skin.grooveLight.withAlphaComponent(0.055),
            lineWidth: 1.0
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()

        if let artwork, artwork.size.width > 1, artwork.size.height > 1 {
            drawAspectFill(artwork, in: rect)
            NSColor(white: 0, alpha: 0.06).setFill()
            rect.fill()
        } else {
            drawPaperLabel(in: rect, title: title, artist: artist, skin: skin)
        }

        NSGraphicsContext.restoreGraphicsState()

        // The edge of the label, and a tiny shadow where it meets the vinyl.
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.35, dy: 0.35))
        edge.lineWidth = 0.8
        NSColor(white: 0, alpha: 0.62).setStroke()
        edge.stroke()

        // The top of the label catches the same light as the vinyl.
        let catchLight = NSBezierPath()
        catchLight.appendArc(
            withCenter: center,
            radius: labelRadius - 0.7,
            startAngle: 34,
            endAngle: 146
        )
        catchLight.lineWidth = 0.5
        skin.grooveLight.withAlphaComponent(0.24).setStroke()
        catchLight.stroke()
    }

    private static func drawPaperLabel(
        in rect: NSRect,
        title: String,
        artist: String,
        skin: VinylSkin
    ) {
        let accent = skin.labelAccent(for: artist + "|" + title)
        accent.setFill()
        rect.fill()

        // Slightly lighter wash at the top-left, like printed paper.
        let wash = NSGradient(
            starting: NSColor(white: 1, alpha: 0.12),
            ending: NSColor(white: 1, alpha: 0)
        )
        wash?.draw(
            in: NSBezierPath(ovalIn: rect),
            relativeCenterPosition: NSPoint(x: -0.34, y: 0.42)
        )

        let ink = VinylTheme.contrastingInk(for: accent)
        let center = NSPoint(x: rect.midX, y: rect.midY)

        // Very faint paper fibres; they should read as texture, not lines.
        ink.withAlphaComponent(0.022).setStroke()
        for i in 0..<7 {
            let y = rect.minY + rect.height * (0.17 + 0.11 * CGFloat(i))
            let inset = rect.width * (0.10 + 0.025 * CGFloat(i % 3))
            let fiber = NSBezierPath()
            fiber.move(to: NSPoint(x: rect.minX + inset, y: y))
            fiber.line(to: NSPoint(x: rect.maxX - inset * 0.85, y: y + 0.35))
            fiber.lineWidth = 0.25
            fiber.stroke()
        }

        let initials = initialsFor(title: title, artist: artist)
        drawCentered(
            initials,
            font: .systemFont(ofSize: 11.5, weight: .semibold),
            color: ink,
            tracking: 0.8,
            centerX: center.x,
            y: center.y + 5.8
        )

        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: center.x - 8.5, y: center.y - 2.7))
        rule.line(to: NSPoint(x: center.x + 8.5, y: center.y - 2.7))
        rule.lineWidth = 0.5
        ink.withAlphaComponent(0.55).setStroke()
        rule.stroke()

        drawCentered(
            "33⅓ RPM",
            font: .systemFont(ofSize: 4.8, weight: .medium),
            color: ink.withAlphaComponent(0.82),
            tracking: 0.55,
            centerX: center.x,
            y: center.y - 8.6
        )

        drawCentered(
            "SIDE A",
            font: .systemFont(ofSize: 3.6, weight: .semibold),
            color: ink.withAlphaComponent(0.55),
            tracking: 1.0,
            centerX: center.x,
            y: center.y - 14.4
        )

        // A tiny printed dot, like a catalogue mark.
        ink.withAlphaComponent(0.40).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x + 11.2,
            y: center.y + 11.0,
            width: 1.4,
            height: 1.4
        )).fill()
    }

    private static func drawSpindle(center: NSPoint, skin: VinylSkin) {
        let holeRadius: CGFloat = 2.3
        let hole = NSRect(
            x: center.x - holeRadius,
            y: center.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        )
        skin.recordCenter.setFill()
        NSBezierPath(ovalIn: hole).fill()

        let rim = NSBezierPath(ovalIn: hole)
        rim.lineWidth = 0.45
        skin.grooveLight.withAlphaComponent(0.32).setStroke()
        rim.stroke()

        // The punched ring around the hole on the paper label.
        let ring = NSBezierPath(ovalIn: hole.insetBy(dx: -1.15, dy: -1.15))
        ring.lineWidth = 0.3
        NSColor(white: 0, alpha: 0.22).setStroke()
        ring.stroke()

        // A pinprick of light in the spindle keeps the centre from going flat.
        NSColor(white: 1, alpha: 0.34).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - 0.55,
            y: center.y + 0.3,
            width: 1.1,
            height: 1.1
        )).fill()
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

    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else {
            return a
        }
        let amount = min(max(t, 0), 1)
        return NSColor(
            srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * amount,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * amount,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * amount,
            alpha: 1
        )
    }
}
