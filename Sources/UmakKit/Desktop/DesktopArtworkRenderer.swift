import AppKit

/// Renders a desktop record once and caches the bitmap.
///
/// Everything on the desktop is a still image: no rotation, no per-frame
/// SwiftUI updates, no animation timer. Re-rendering only happens when the item
/// is created, the record is pulled out or tucked in, or the skin changes.
enum DesktopArtworkRenderer {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Bitmap scale for the finished object and its shadows. Kept as one
    /// constant so the cache cost and the rendered pixels cannot drift apart.
    private static let scale: CGFloat = 2

    /// Drops composed record bitmaps. Visible layers keep their own image
    /// references, so purging only releases entries nothing else is using.
    static func purge() {
        cache.removeAllObjects()
    }

    static func image(
        for style: DesktopRecordStyle,
        recordOut: Bool,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> NSImage {
        let key = cacheKey(
            style: style,
            recordOut: recordOut,
            snapshot: snapshot,
            artwork: artwork,
            skin: skin
        )
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let image = render(
            style: style,
            recordOut: recordOut,
            snapshot: snapshot,
            artwork: artwork,
            skin: skin
        )
        let window = DesktopRecordGeometry.windowSize(for: style, recordOut: recordOut)
        let pixelsWide = Int(ceil(window.width * scale))
        let pixelsHigh = Int(ceil(window.height * scale))
        cache.setObject(
            image,
            forKey: key as NSString,
            cost: pixelsWide * pixelsHigh * 4
        )
        return image
    }

    private static func cacheKey(
        style: DesktopRecordStyle,
        recordOut: Bool,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> String {
        let art = snapshot.artworkFile
            ?? artwork.map { "obj:\(ObjectIdentifier($0).hashValue)" }
            ?? "none"
        return [
            style.rawValue,
            recordOut ? "out" : "in",
            skin.id,
            snapshot.persistentID,
            snapshot.title,
            snapshot.artist,
            snapshot.album,
            art,
        ].joined(separator: "|")
    }

    // MARK: - Composition

    private static func render(
        style: DesktopRecordStyle,
        recordOut: Bool,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> NSImage {
        let item = DesktopRecordGeometry.itemSize(for: style, recordOut: recordOut)
        let padding = DesktopRecordGeometry.shadowPadding
        let pointSize = NSSize(
            width: item.width + padding * 2,
            height: item.height + padding * 2
        )

        // Compose the physical object at item size first, then cast the three
        // shadow layers from that one silhouette. Casting per-piece would give
        // the vinyl and the cover separate shadows and break the illusion that
        // the record is inside the sleeve.
        guard let object = renderObject(
            style: style,
            recordOut: recordOut,
            snapshot: snapshot,
            artwork: artwork,
            skin: skin
        ) else {
            return NSImage(size: pointSize)
        }
        guard let (rep, ctx) = makeBitmap(pointSize: pointSize, scale: scale) else {
            // Keep the returned image at the window's advertised size even if
            // the final bitmap allocation fails; an item-sized image would be
            // stretched by the content layer and no longer match hit testing.
            return NSImage(size: pointSize)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: pointSize).fill()

        let target = NSRect(x: padding, y: padding, width: item.width, height: item.height)

        // Ambient: wide and low, the shadow of something suspended a little
        // above the desktop.
        drawShadowed(object, in: target, alpha: 0.10, blur: 38, offset: NSSize(width: 0, height: -2))
        // Key: light from the upper left, so the shadow falls right and down.
        drawShadowed(object, in: target, alpha: 0.26, blur: 16, offset: NSSize(width: 5, height: -7))
        // Contact: tight and nearly black where the object meets the surface.
        drawShadowed(object, in: target, alpha: 0.38, blur: 2.5, offset: NSSize(width: 0, height: -1))

        // The object itself goes last so the three shadow passes never tint
        // its face. The shadows drawn above remain around the silhouette.
        object.draw(in: target)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// Draws the object at item size with no shadow. The result is composited
    /// onto the padded canvas by `render`.
    private static func renderObject(
        style: DesktopRecordStyle,
        recordOut: Bool,
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) -> NSImage? {
        let item = DesktopRecordGeometry.itemSize(for: style, recordOut: recordOut)
        guard let (rep, ctx) = makeBitmap(pointSize: item, scale: scale) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: item).fill()

        switch style {
        case .disc:
            let discRect = DesktopRecordGeometry.discRect(for: style, recordOut: recordOut)
            drawDisc(in: discRect, snapshot: snapshot, artwork: artwork, skin: skin)
        case .sleeve:
            if recordOut {
                drawOpenSleeve(snapshot: snapshot, artwork: artwork, skin: skin)
            } else {
                drawClosedSleeve(snapshot: snapshot, artwork: artwork, skin: skin)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: item)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Sleeve

    /// The record is out: the disc sits behind the cover, exposed on the
    /// right, and the cover is drawn last and fully opaque.
    private static func drawOpenSleeve(
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) {
        let coverRect = DesktopRecordGeometry.coverRect(for: .sleeve, recordOut: true)
        let discRect = DesktopRecordGeometry.discRect(for: .sleeve, recordOut: true)

        if discRect.width > 1, discRect.height > 1 {
            if let disc = RecordTexture.make(
                radius: discRect.width / 2,
                labelRadius: DesktopRecordGeometry.labelDiameter / 2,
                artwork: artwork,
                title: snapshot.title,
                artist: snapshot.artist,
                skin: skin,
                scale: scale
            ) {
                disc.draw(in: discRect)
            } else {
                skin.recordCenter.setFill()
                NSBezierPath(ovalIn: discRect).fill()
            }

            // The cover's right edge blocks light from the exposed vinyl. The
            // gradient is the cue that the record is tucked under the board
            // rather than floating on top of it.
            drawMouthShadow(from: coverRect.maxX, in: discRect)
        }

        drawCover(in: coverRect, snapshot: snapshot, artwork: artwork, skin: skin)
    }

    /// The record is in: only the sleeve exists. Nothing of the vinyl is drawn,
    /// so there is no stray disc edge or vinyl shadow to give it away.
    private static func drawClosedSleeve(
        snapshot: TrackSnapshot,
        artwork: NSImage?,
        skin: VinylSkin
    ) {
        let coverRect = DesktopRecordGeometry.coverRect(for: .sleeve, recordOut: false)
        drawCover(in: coverRect, snapshot: snapshot, artwork: artwork, skin: skin)
    }

    /// Soft shadow cast by the cover's mouth onto the record behind it.
    ///
    /// A horizontal gradient leaves the cover edge at its darkest and fades
    /// across the exposed vinyl. It is clipped to the disc and multiplied by a
    /// vertical gradient so it dies out at the disc's top and bottom instead of
    /// ending in a hard band.
    private static func drawMouthShadow(from edge: CGFloat, in disc: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }

        let reach: CGFloat = 13
        let space = CGColorSpaceCreateDeviceRGB()
        guard let shade = CGColor(colorSpace: space, components: [0, 0, 0, 0.42]),
              let clear = CGColor(colorSpace: space, components: [0, 0, 0, 0]) else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: disc).addClip()

        cg.beginTransparencyLayer(auxiliaryInfo: nil)

        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [shade, clear] as CFArray,
            locations: [0, 1]
        ) {
            cg.drawLinearGradient(
                gradient,
                start: CGPoint(x: edge, y: disc.midY),
                end: CGPoint(x: edge + reach, y: disc.midY),
                options: [.drawsBeforeStartLocation]
            )
        }

        // Keep only the part of the band that falls inside the exposed arc's
        // vertical span, with a soft roll-off at both ends.
        cg.setBlendMode(.destinationIn)
        guard let fork = CGColor(colorSpace: space, components: [0, 0, 0, 0]),
              let full = CGColor(colorSpace: space, components: [0, 0, 0, 1]) else {
            cg.endTransparencyLayer()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if let mask = CGGradient(
            colorsSpace: space,
            colors: [fork, full, full, fork] as CFArray,
            locations: [0, 0.14, 0.86, 1]
        ) {
            cg.drawLinearGradient(
                mask,
                start: CGPoint(x: disc.midX, y: disc.minY),
                end: CGPoint(x: disc.midX, y: disc.maxY),
                options: []
            )
        }
        cg.setBlendMode(.normal)
        cg.endTransparencyLayer()

        NSGraphicsContext.restoreGraphicsState()
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
            disc.draw(in: rect)
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

        // Physical thickness: a dark lip at the silhouette and a thin
        // catchlight just inside it.
        let lip = NSBezierPath(ovalIn: rect.insetBy(dx: 0.55, dy: 0.55))
        lip.lineWidth = 1.15
        NSColor(white: 0, alpha: 0.48).setStroke()
        lip.stroke()

        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 1.7, dy: 1.7))
        rim.lineWidth = 0.7
        skin.sheen.withAlphaComponent(0.24).setStroke()
        rim.stroke()
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

        drawCoverBoard(in: rect)
    }

    /// Board thickness and the sleeve mouth, shared by both sleeve states so
    /// the front face reads the same whether or not the record is out.
    private static func drawCoverBoard(in rect: NSRect) {
        // Right and bottom sit in shade: the cut paper edge, slightly darker
        // than the printed face.
        NSColor(white: 0, alpha: 0.14).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2).fill()
        NSRect(x: rect.maxX - 2, y: rect.minY, width: 2, height: rect.height).fill()

        // Top and left catch the light as a thin cut edge.
        let cut = NSBezierPath()
        cut.move(to: NSPoint(x: rect.minX + 0.4, y: rect.maxY - 0.6))
        cut.line(to: NSPoint(x: rect.maxX - 0.4, y: rect.maxY - 0.6))
        cut.move(to: NSPoint(x: rect.minX + 0.6, y: rect.minY + 0.4))
        cut.line(to: NSPoint(x: rect.minX + 0.6, y: rect.maxY - 0.4))
        cut.lineWidth = 0.8
        NSColor.white.withAlphaComponent(0.30).setStroke()
        cut.stroke()

        // The mouth: a dark slit along the opening edge with a cream paper
        // line just inside it.
        let slitWidth: CGFloat = 1.5
        NSColor(white: 0, alpha: 0.55).setFill()
        NSRect(
            x: rect.maxX - slitWidth,
            y: rect.minY,
            width: slitWidth,
            height: rect.height
        ).fill()

        NSColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 0.62).setFill()
        NSRect(
            x: rect.maxX - slitWidth - 0.9,
            y: rect.minY,
            width: 0.5,
            height: rect.height
        ).fill()
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

        let ink = VinylTheme.contrastingInk(for: accent)
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

    private static func drawShadowed(
        _ image: NSImage,
        in rect: NSRect,
        alpha: CGFloat,
        blur: CGFloat,
        offset: NSSize
    ) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = offset
        shadow.set()
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

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
}
