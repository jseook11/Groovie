import AppKit

/// Renders a desktop record once and caches the bitmap.
///
/// Everything on the desktop is a still image: no rotation, no per-frame
/// SwiftUI updates, no animation timer. Re-rendering only happens when the item
/// is created or the record skin changes.
enum DesktopArtworkRenderer {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func image(
        for style: DesktopRecordStyle,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> NSImage {
        let key = cacheKey(style: style, snapshot: snapshot, artwork: artwork, skin: skin)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let image = render(style: style, snapshot: snapshot, artwork: artwork, skin: skin)
        let item = DesktopRecordGeometry.windowSize(for: style)
        cache.setObject(
            image,
            forKey: key as NSString,
            cost: Int(item.width * item.height * 4)
        )
        return image
    }

    private static func cacheKey(
        style: DesktopRecordStyle,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> String {
        let art = snapshot.artworkFile
            ?? artwork.map { "obj:\(ObjectIdentifier($0).hashValue)" }
            ?? "none"
        return [
            style.rawValue,
            skin.id,
            snapshot.persistentID,
            snapshot.title,
            snapshot.artist,
            snapshot.album,
            art,
        ].joined(separator: "|")
    }

    private static func render(
        style: DesktopRecordStyle,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> NSImage {
        let item = DesktopRecordGeometry.itemSize(for: style)
        let padding = DesktopRecordGeometry.shadowPadding
        let pointSize = NSSize(
            width: item.width + padding * 2,
            height: item.height + padding * 2
        )
        let scale: CGFloat = 2

        guard let (rep, ctx) = makeBitmap(pointSize: pointSize, scale: scale) else {
            return NSImage(size: pointSize)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: pointSize).fill()

        let itemRect = NSRect(x: padding, y: padding, width: item.width, height: item.height)
        switch style {
        case .disc:
            drawDisc(in: itemRect, snapshot: snapshot, artwork: artwork, skin: skin)
        case .sleeve:
            drawSleeve(in: itemRect, snapshot: snapshot, artwork: artwork, skin: skin)
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Disc

    private static func drawDisc(
        in rect: NSRect,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) {
        let radius = rect.width / 2
        let labelRadius = DesktopRecordGeometry.labelDiameter / 2

        if let disc = RecordTexture.make(
            radius: radius,
            labelRadius: labelRadius,
            artwork: artwork,
            title: snapshot.title,
            artist: snapshot.artist,
            skin: skin,
            scale: 3
        ) {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
            shadow.shadowBlurRadius = 13
            shadow.shadowOffset = NSSize(width: 0, height: -5)
            shadow.set()
            disc.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            skin.recordCenter.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        // The fixed turntable light. The record itself never rotates, so the
        // highlight stays put and the item reads as a physical object.
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let strength = skin.sheenStrength
        if let sheen = NSGradient(colors: [
            skin.sheen.withAlphaComponent(0.10 * strength),
            .clear,
            skin.sheen.withAlphaComponent(0.04 * strength),
            .clear,
            skin.sheen.withAlphaComponent(0.07 * strength),
            .clear,
        ]) {
            sheen.draw(in: rect, angle: -35)
        }
        let hotspot = NSRect(
            x: rect.minX + rect.width * 0.08,
            y: rect.minY + rect.height * 0.52,
            width: rect.width * 0.55,
            height: rect.height * 0.55
        )
        if let glow = NSGradient(colors: [
            skin.sheen.withAlphaComponent(0.10 * strength),
            .clear,
        ]) {
            glow.draw(in: NSBezierPath(ovalIn: hotspot), relativeCenterPosition: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()

        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.45, dy: 0.45))
        rim.lineWidth = 0.9
        skin.sheen.withAlphaComponent(0.22).setStroke()
        rim.stroke()
    }

    // MARK: - Sleeve

    private static func drawSleeve(
        in rect: NSRect,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) {
        let coverSide = DesktopRecordGeometry.coverSide
        let peek = DesktopRecordGeometry.sleevePeek
        let itemSize = rect.size
        let scale: CGFloat = 2

        // Compose the cover and sleeve first so one shadow belongs to the
        // whole object instead of each piece casting its own.
        guard let (itemRep, itemCtx) = makeBitmap(pointSize: itemSize, scale: scale) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = itemCtx
        itemCtx.shouldAntialias = true
        itemCtx.imageInterpolation = .high
        itemCtx.cgContext.scaleBy(x: scale, y: scale)

        let local = NSRect(origin: .zero, size: itemSize)
        NSColor.clear.setFill()
        local.fill()

        let coverRect = NSRect(x: 0, y: 0, width: coverSide, height: coverSide)
        let sleeveRect = NSRect(x: peek, y: 0, width: coverSide, height: coverSide)
        let vinylRect = NSRect(
            x: sleeveRect.midX - DesktopRecordGeometry.discDiameter / 2,
            y: sleeveRect.midY - DesktopRecordGeometry.discDiameter / 2,
            width: DesktopRecordGeometry.discDiameter,
            height: DesktopRecordGeometry.discDiameter
        )
        let paper = NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1)

        // The sleeve body, then the record, then a translucent paper skin so
        // the vinyl shows through exactly as it does in a paper inner sleeve.
        paper.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: sleeveRect, xRadius: 3, yRadius: 3).fill()

        if let disc = RecordTexture.make(
            radius: DesktopRecordGeometry.discDiameter / 2,
            labelRadius: DesktopRecordGeometry.labelDiameter / 2,
            artwork: artwork,
            title: snapshot.title,
            artist: snapshot.artist,
            skin: skin,
            scale: 2
        ) {
            disc.draw(in: vinylRect)
        }

        paper.withAlphaComponent(0.52).setFill()
        NSBezierPath(roundedRect: sleeveRect, xRadius: 3, yRadius: 3).fill()

        // Top seam of the paper sleeve.
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: sleeveRect.minX + 9, y: sleeveRect.maxY - 11))
        seam.line(to: NSPoint(x: sleeveRect.maxX - 9, y: sleeveRect.maxY - 11))
        seam.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.72).setStroke()
        seam.stroke()

        let sleeveEdge = NSBezierPath(
            roundedRect: sleeveRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 3,
            yRadius: 3
        )
        sleeveEdge.lineWidth = 0.8
        NSColor.black.withAlphaComponent(0.18).setStroke()
        sleeveEdge.stroke()

        // The cover sits in front and casts a short shadow onto the sleeve.
        NSGraphicsContext.saveGraphicsState()
        let coverShadow = NSShadow()
        coverShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        coverShadow.shadowBlurRadius = 7
        coverShadow.shadowOffset = NSSize(width: 4, height: -3)
        coverShadow.set()
        drawCover(in: coverRect, snapshot: snapshot, artwork: artwork, skin: skin)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()

        let itemImage = NSImage(size: itemSize)
        itemImage.addRepresentation(itemRep)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        itemImage.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Cover

    private static func drawCover(
        in rect: NSRect,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()

        if let artwork, artwork.size.width > 1, artwork.size.height > 1 {
            drawAspectFill(artwork, in: rect)
            NSColor(white: 0, alpha: 0.04).setFill()
            rect.fill()
        } else {
            drawGeneratedCover(in: rect, snapshot: snapshot, skin: skin)
        }

        NSGraphicsContext.restoreGraphicsState()

        let edge = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        NSColor.black.withAlphaComponent(0.32).setStroke()
        edge.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: rect.minX + 0.8, y: rect.maxY - 0.8))
        highlight.line(to: NSPoint(x: rect.maxX - 0.8, y: rect.maxY - 0.8))
        highlight.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.22).setStroke()
        highlight.stroke()
    }

    private static func drawGeneratedCover(
        in rect: NSRect,
        snapshot: TrackSnapshot,
        skin: VinylSkin
    ) {
        let seed = "\(snapshot.artist)|\(snapshot.album)|\(snapshot.title)"
        let accent = skin.labelAccent(for: seed)
        accent.setFill()
        rect.fill()

        if let wash = NSGradient(
            starting: NSColor(white: 1, alpha: 0.16),
            ending: NSColor(white: 1, alpha: 0)
        ) {
            wash.draw(
                in: NSBezierPath(rect: rect),
                relativeCenterPosition: NSPoint(x: -0.42, y: 0.46)
            )
        }

        let ink = contrastingInk(for: accent)
        let margin: CGFloat = 16
        let titleFont = NSFont.systemFont(ofSize: 18, weight: .bold)
        let artistFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 6.5, weight: .semibold)

        let title = fitted(
            (snapshot.album.isEmpty ? snapshot.title : snapshot.album).uppercased(),
            font: titleFont,
            maxWidth: rect.width - margin * 2
        )
        let artist = fitted(
            snapshot.artist.isEmpty ? snapshot.title : snapshot.artist,
            font: artistFont,
            maxWidth: rect.width - margin * 2
        )

        var y = rect.maxY - margin - titleFont.pointSize
        drawText(title, font: titleFont, color: ink, tracking: 0.2, at: NSPoint(x: rect.minX + margin, y: y))
        y -= artistFont.pointSize + 7
        drawText(
            artist,
            font: artistFont,
            color: ink.withAlphaComponent(0.82),
            tracking: 0.5,
            at: NSPoint(x: rect.minX + margin, y: y)
        )

        y -= 12
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: rect.minX + margin, y: y))
        rule.line(to: NSPoint(x: rect.maxX - margin, y: y))
        rule.lineWidth = 0.6
        ink.withAlphaComponent(0.45).setStroke()
        rule.stroke()

        drawText(
            "SIDE A",
            font: smallFont,
            color: ink.withAlphaComponent(0.60),
            tracking: 1.0,
            at: NSPoint(x: rect.minX + margin, y: rect.minY + margin)
        )
        let rpm = "33⅓ RPM" as NSString
        let rpmSize = rpm.size(withAttributes: [.font: smallFont, .kern: 0.5])
        rpm.draw(
            at: NSPoint(x: rect.maxX - margin - rpmSize.width, y: rect.minY + margin),
            withAttributes: [.font: smallFont, .foregroundColor: ink.withAlphaComponent(0.60), .kern: 0.5]
        )

        let mark = NSBezierPath(ovalIn: NSRect(
            x: rect.maxX - margin - 3,
            y: rect.maxY - margin - 3,
            width: 3,
            height: 3
        ))
        ink.withAlphaComponent(0.45).setFill()
        mark.fill()
    }

    // MARK: - Drawing helpers

    private static func makeBitmap(
        pointSize: NSSize,
        scale: CGFloat
    ) -> (NSBitmapImageRep, NSGraphicsContext)? {
        let pixelsWide = Int(ceil(pointSize.width * scale))
        let pixelsHigh = Int(ceil(pointSize.height * scale))
        guard pixelsWide > 8, pixelsHigh > 8,
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
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = pointSize
        return (rep, ctx)
    }

    private static func drawText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        tracking: CGFloat,
        at point: NSPoint
    ) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .kern: tracking,
            ]
        )
    }

    private static func fitted(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= maxWidth {
            return text
        }
        var result = text
        while !result.isEmpty {
            result.removeLast()
            let candidate = result + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= maxWidth {
                return candidate
            }
        }
        return "…"
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

    private static func contrastingInk(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return VinylTheme.labelCream }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.56 ? VinylTheme.labelInk : VinylTheme.labelCream
    }
}
