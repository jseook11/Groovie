import AppKit
import CoreGraphics
import Foundation

/// A decorative copy of the record that currently sits in the notch.
///
/// This is a snapshot, not a live reference: changing tracks, pausing, or
/// quitting Music never changes an item on the desktop. Nothing here is meant
/// to be played, scrubbed, or skipped.
struct TrackSnapshot: Codable, Equatable {
    var persistentID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// File name inside the store's `artwork/` directory. Nil when the track
    /// had no artwork; the record is then drawn from its printed label.
    var artworkFile: String?

    init(
        persistentID: String,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        artworkFile: String? = nil
    ) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkFile = artworkFile
    }
}

/// Two static presentations of the same snapshot.
enum DesktopRecordStyle: String, Codable, CaseIterable {
    /// The bare vinyl, the same record the notch renders.
    case disc
    /// The album cover with the record tucked into its inner sleeve.
    case sleeve
}

struct DesktopRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var track: TrackSnapshot
    let style: DesktopRecordStyle
    /// Centre of the item in global screen coordinates.
    var position: CGPoint
    /// `NSScreenNumber` of the display the item belongs to, when known.
    var screenID: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        track: TrackSnapshot,
        style: DesktopRecordStyle,
        position: CGPoint,
        screenID: String?,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.track = track
        self.style = style
        self.position = position
        self.screenID = screenID
        self.createdAt = createdAt
    }
}

/// On-disk document. The version field leaves room for a migration without
/// having to guess the shape of older files.
struct DesktopRecordDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var records: [DesktopRecord]

    init(version: Int = DesktopRecordDocument.currentVersion, records: [DesktopRecord]) {
        self.version = version
        self.records = records
    }
}

/// Geometry shared by the window controller and the headless checks.
enum DesktopRecordGeometry {
    static let discDiameter: CGFloat = 180
    static let labelDiameter: CGFloat = 60
    static let coverSide: CGFloat = 200
    static let sleevePeek: CGFloat = 70
    /// Transparent margin around the item so its baked-in shadow is not clipped.
    static let shadowPadding: CGFloat = 18
    static let cascadeStep: CGFloat = 24
    static let cascadeCount = 5
    static let maxRecords = 100

    static func itemSize(for style: DesktopRecordStyle) -> CGSize {
        switch style {
        case .disc:
            return CGSize(width: discDiameter, height: discDiameter)
        case .sleeve:
            return CGSize(width: coverSide + sleevePeek, height: coverSide)
        }
    }

    static func windowSize(for style: DesktopRecordStyle) -> CGSize {
        let item = itemSize(for: style)
        return CGSize(
            width: item.width + shadowPadding * 2,
            height: item.height + shadowPadding * 2
        )
    }

    /// Keep the whole item inside the visible frame. `frame` is expected to be
    /// the screen's `visibleFrame`, so the menu bar and Dock stay clear.
    static func clamp(_ position: CGPoint, itemSize: CGSize, to frame: CGRect) -> CGPoint {
        // Display hot-plug can momentarily leave no usable screen. Returning
        // the original position keeps that transient from rewriting every
        // record to the origin.
        guard frame.width > 0, frame.height > 0 else { return position }

        let halfWidth = min(itemSize.width / 2, frame.width / 2)
        let halfHeight = min(itemSize.height / 2, frame.height / 2)
        return CGPoint(
            x: min(max(position.x, frame.minX + halfWidth), frame.maxX - halfWidth),
            y: min(max(position.y, frame.minY + halfHeight), frame.maxY - halfHeight)
        )
    }

    /// The top-centre strip that removes a desktop item when the pointer is
    /// released inside it.
    static func deleteZone(notchRect: CGRect, screenFrame: CGRect) -> CGRect {
        let width = max(notchRect.width + 160, 320)
        let height = max(notchRect.height + 80, 120)
        return CGRect(
            x: notchRect.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    static func isInDeleteZone(_ point: CGPoint, notchRect: CGRect, screenFrame: CGRect) -> Bool {
        deleteZone(notchRect: notchRect, screenFrame: screenFrame).contains(point)
    }

    /// First package slot: top centre, below the delete zone, then a short
    /// down-right cascade so repeated clicks do not stack exactly.
    static func defaultSlot(
        itemSize: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        notchHeight: CGFloat,
        index: Int
    ) -> CGPoint {
        let topInset = notchHeight + 80 + 16
        let step = cascadeStep * CGFloat(index % cascadeCount)
        let candidate = CGPoint(
            x: screenFrame.midX + step,
            y: screenFrame.maxY - topInset - itemSize.height / 2 - step
        )
        return clamp(candidate, itemSize: itemSize, to: visibleFrame)
    }

    /// Screen identity that survives a relaunch. Display IDs can change when
    /// cables are swapped, so callers must still fall back to the main screen.
    static func screenID(for screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.stringValue
    }
}
