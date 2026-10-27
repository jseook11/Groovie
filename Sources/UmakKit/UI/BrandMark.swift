import AppKit

/// The Umak mark: a wide notch housing with the lower half of a record
/// emerging beneath it.
///
/// The mark is drawn in code rather than downscaled from the raster app icon so
/// the menu bar symbol stays crisp at 1x/2x and can follow the current label
/// colour inside the menu.
enum BrandMark {
    /// The 20 x 11 pt optical box used by the menu bar and the menu header.
    static let menuBarSize = NSSize(width: 20, height: 11)

    /// A monochrome template image. AppKit tints it for light and dark menu bars.
    static var menuBar: NSImage {
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Fill the mark in the current context.
    static func draw(in rect: NSRect, color: NSColor) {
        color.setFill()
        path(in: rect).fill()
    }

    /// The connected silhouette, normalised to a 20 x 11 pt box.
    ///
    /// Geometry follows the design spec: the record diameter is D, the housing
    /// is 1.35D wide and 0.22D tall, and the record's centre sits exactly on the
    /// housing's bottom edge. Only the lower half of the record is drawn; the
    /// upper half is hidden by the housing. The spindle hole punches through the
    /// shared edge.
    static func path(in rect: NSRect) -> NSBezierPath {
        let boxHeight = rect.height
        // The full mark is 0.72D tall (0.22D housing + 0.5D record).
        let diameter = boxHeight * 0.85 / 0.72
        let radius = diameter / 2
        let notchWidth = diameter * 1.35
        let notchHeight = diameter * 0.22
        let totalHeight = notchHeight + radius
        let bottomInset = (boxHeight - totalHeight) / 2

        let center = NSPoint(
            x: rect.midX,
            y: rect.minY + bottomInset + radius
        )
        let notchLeft = rect.midX - notchWidth / 2
        let notchRight = rect.midX + notchWidth / 2
        let notchTop = center.y + notchHeight
        let cornerRadius = max(0.55, diameter * 0.05)

        let path = NSBezierPath()
        path.windingRule = .evenOdd

        // Housing: straight top edge, softly rounded bottom corners.
        path.move(to: NSPoint(x: notchLeft, y: notchTop))
        path.line(to: NSPoint(x: notchRight, y: notchTop))
        path.line(to: NSPoint(x: notchRight, y: center.y + cornerRadius))
        path.appendArc(
            withCenter: NSPoint(x: notchRight - cornerRadius, y: center.y + cornerRadius),
            radius: cornerRadius,
            startAngle: 0,
            endAngle: 270,
            clockwise: true
        )
        path.line(to: NSPoint(x: notchLeft + cornerRadius, y: center.y))
        path.appendArc(
            withCenter: NSPoint(x: notchLeft + cornerRadius, y: center.y + cornerRadius),
            radius: cornerRadius,
            startAngle: 270,
            endAngle: 180,
            clockwise: true
        )
        path.line(to: NSPoint(x: notchLeft, y: notchTop))
        path.close()

        // Visible lower half of the record.
        path.move(to: NSPoint(x: center.x - radius, y: center.y))
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 180,
            endAngle: 360,
            clockwise: false
        )
        path.close()

        // Punched spindle hole at the boundary. At 20 x 11 pt the proportional
        // hole (0.035D) is sub-pixel, so it is optically enlarged to 1.1 pt.
        let holeRadius = max(0.55, diameter * 0.042)
        path.append(NSBezierPath(ovalIn: NSRect(
            x: center.x - holeRadius,
            y: center.y - holeRadius,
            width: holeRadius * 2,
            height: holeRadius * 2
        )))

        return path
    }
}

/// Draws the mark in the current label colour, for use inside the menu.
final class BrandMarkView: NSView {
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { BrandMark.menuBarSize }

    override func draw(_ dirtyRect: NSRect) {
        BrandMark.draw(in: bounds, color: .labelColor)
    }
}
