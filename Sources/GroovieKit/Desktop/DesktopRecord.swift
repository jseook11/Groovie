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
    var style: DesktopRecordStyle
    /// Anchor point in global screen coordinates.
    ///
    /// This is deliberately *not* the centre of the item rectangle. For a
    /// `.disc` the anchor is the centre of the 180x180 disc. For a `.sleeve`
    /// the anchor is the centre of the 200x200 cover, which stays put whether
    /// the record is out (`recordOut == true`, 272x200 item) or tucked away
    /// (`recordOut == false`, 200x200 item). Treating it as an anchor lets the
    /// item slide out from behind the cover without moving the cover itself.
    var position: CGPoint
    /// `NSScreenNumber` of the display the item belongs to, when known.
    var screenID: String?
    /// Whether a sleeve shows its record slid out to the right. Ignored by
    /// `.disc`, which has no sleeve. Defaults to true so records written by
    /// older versions — and newly created ones — start in the open state.
    var recordOut: Bool
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case track
        case style
        case position
        case screenID
        case recordOut
        case createdAt
    }

    init(
        id: UUID = UUID(),
        track: TrackSnapshot,
        style: DesktopRecordStyle,
        position: CGPoint,
        screenID: String?,
        createdAt: Date = Date(),
        recordOut: Bool = true
    ) {
        self.id = id
        self.track = track
        self.style = style
        self.position = position
        self.screenID = screenID
        self.recordOut = recordOut
        self.createdAt = createdAt
    }

    /// Decode by hand so documents written before `recordOut` existed still
    /// load. Every other field is identical to the synthesized behaviour; the
    /// encode side stays synthesized so `recordOut` is always written back.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        track = try container.decode(TrackSnapshot.self, forKey: .track)
        style = try container.decode(DesktopRecordStyle.self, forKey: .style)
        position = try container.decode(CGPoint.self, forKey: .position)
        screenID = try container.decodeIfPresent(String.self, forKey: .screenID)
        recordOut = try container.decodeIfPresent(Bool.self, forKey: .recordOut) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// On-disk document. The version field leaves room for a migration without
/// having to guess the shape of older files.
///
/// * Version 1 stored an item-centre position and had no `recordOut` flag.
/// * Version 2 stores an anchor (see `DesktopRecord.position`) and adds
///   `recordOut`. Decoding a v1 file shifts each sleeve's x by -35 pt to turn
///   the old item centre into the cover centre; disc positions already used
///   the disc centre and are left untouched. The migrated document reports its
///   original version so the store knows to write the upgrade back to disk.
struct DesktopRecordDocument: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var records: [DesktopRecord]

    private enum CodingKeys: String, CodingKey {
        case version
        case records
    }

    init(version: Int = DesktopRecordDocument.currentVersion, records: [DesktopRecord]) {
        self.version = version
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        var decoded = try container.decode([DesktopRecord].self, forKey: .records)

        if storedVersion < 2 {
            // v1 sleeve positions were the centre of the whole 270x200 item;
            // the anchor is the centre of the 200x200 cover, 35 pt to the
            // left. v1 records were always shown with the record out.
            for index in decoded.indices where decoded[index].style == .sleeve {
                decoded[index].position.x -= 35
                decoded[index].recordOut = true
            }
        }

        version = storedVersion
        records = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(records, forKey: .records)
    }
}

/// Geometry shared by the window controller and the headless checks.
///
/// Positions are stored as anchors, never as window or item centres. The
/// helpers below convert between the anchor, the item rectangle (the visible
/// object without its shadow margin), and the window rectangle (which adds
/// `shadowPadding` on every side).
enum DesktopRecordGeometry {
    static let discDiameter: CGFloat = 180
    static let labelDiameter: CGFloat = 60
    static let coverSide: CGFloat = 200
    /// How much of the disc protrudes to the right of a sleeve when it is out.
    static let sleeveExposed: CGFloat = 72
    static let sleeveOpenWidth: CGFloat = coverSide + sleeveExposed
    static let sleeveClosedWidth: CGFloat = coverSide
    /// Transparent margin around the item so its baked-in shadow is not clipped.
    static let shadowPadding: CGFloat = 34
    static let cascadeStep: CGFloat = 24
    static let cascadeCount = 5
    static let maxRecords = 100

    /// Deprecated compatibility alias for the renderer's old call site. New
    /// code should use `sleeveExposed`.
    static let sleevePeek: CGFloat = sleeveExposed

    // MARK: - Sizes

    /// The visible object's size, without the transparent shadow margin.
    ///
    /// A `.disc` is always square. A `.sleeve` is 272x200 with the record out
    /// and 200x200 with it hidden. `recordOut` is ignored for `.disc`.
    static func itemSize(for style: DesktopRecordStyle, recordOut: Bool) -> CGSize {
        switch style {
        case .disc:
            return CGSize(width: discDiameter, height: discDiameter)
        case .sleeve:
            return CGSize(
                width: recordOut ? sleeveOpenWidth : sleeveClosedWidth,
                height: coverSide
            )
        }
    }

    /// Compatibility overload for callers that predate `recordOut`.
    static func itemSize(for style: DesktopRecordStyle) -> CGSize {
        itemSize(for: style, recordOut: true)
    }

    /// The full window size: the item plus the shadow margin on all sides.
    static func windowSize(for style: DesktopRecordStyle, recordOut: Bool) -> CGSize {
        let item = itemSize(for: style, recordOut: recordOut)
        return CGSize(
            width: item.width + shadowPadding * 2,
            height: item.height + shadowPadding * 2
        )
    }

    /// Compatibility overload for callers that predate `recordOut`.
    static func windowSize(for style: DesktopRecordStyle) -> CGSize {
        windowSize(for: style, recordOut: true)
    }

    // MARK: - Rects (item coordinates, origin at the item's bottom-left)

    /// The album cover. `.sleeve` always returns (0, 0, 200, 200), whether the
    /// record is out or hidden. `.disc` has no cover and returns its disc rect.
    static func coverRect(for style: DesktopRecordStyle, recordOut: Bool) -> CGRect {
        switch style {
        case .disc:
            return CGRect(x: 0, y: 0, width: discDiameter, height: discDiameter)
        case .sleeve:
            return CGRect(x: 0, y: 0, width: coverSide, height: coverSide)
        }
    }

    /// The disc. For an open sleeve it is (92, 10, 180, 180): 72 pt of it sticks
    /// out past the cover's right edge. For a closed sleeve the disc is tucked
    /// fully behind the cover, flush with its right edge.
    static func discRect(for style: DesktopRecordStyle, recordOut: Bool) -> CGRect {
        switch style {
        case .disc:
            return CGRect(x: 0, y: 0, width: discDiameter, height: discDiameter)
        case .sleeve:
            let x: CGFloat
            if recordOut {
                x = sleeveOpenWidth - discDiameter // 92: right edge at 272
            } else {
                x = sleeveClosedWidth - discDiameter // 20: right edge at 200
            }
            let y = (coverSide - discDiameter) / 2 // 10
            return CGRect(x: x, y: y, width: discDiameter, height: discDiameter)
        }
    }

    // MARK: - Anchor conversion

    /// Where the record anchor sits inside the item rectangle. For a sleeve
    /// this is the cover centre; for a disc it is the item/disc centre. It is
    /// constant across `recordOut` so sliding the record out never moves the
    /// cover.
    static func anchorOffset(for style: DesktopRecordStyle, recordOut: Bool) -> CGPoint {
        switch style {
        case .disc:
            return CGPoint(x: discDiameter / 2, y: discDiameter / 2)
        case .sleeve:
            return CGPoint(x: coverSide / 2, y: coverSide / 2)
        }
    }

    /// Window origin (in screen coordinates) for an anchor. The anchor sits at
    /// `shadowPadding + anchorOffset` inside the window.
    static func windowOrigin(
        anchor: CGPoint,
        style: DesktopRecordStyle,
        recordOut: Bool
    ) -> CGPoint {
        let offset = anchorOffset(for: style, recordOut: recordOut)
        return CGPoint(
            x: anchor.x - (shadowPadding + offset.x),
            y: anchor.y - (shadowPadding + offset.y)
        )
    }

    /// Inverse of `windowOrigin(anchor:style:recordOut:)`.
    static func anchor(
        windowOrigin: CGPoint,
        style: DesktopRecordStyle,
        recordOut: Bool
    ) -> CGPoint {
        let offset = anchorOffset(for: style, recordOut: recordOut)
        return CGPoint(
            x: windowOrigin.x + shadowPadding + offset.x,
            y: windowOrigin.y + shadowPadding + offset.y
        )
    }

    /// The visible item's centre in screen coordinates, derived from the
    /// anchor. A disc's centre is its anchor; an open sleeve's item centre is
    /// 36 pt to the right of its cover centre.
    static func itemCenter(
        anchor: CGPoint,
        style: DesktopRecordStyle,
        recordOut: Bool
    ) -> CGPoint {
        let offset = anchorOffset(for: style, recordOut: recordOut)
        let size = itemSize(for: style, recordOut: recordOut)
        return CGPoint(
            x: anchor.x - offset.x + size.width / 2,
            y: anchor.y - offset.y + size.height / 2
        )
    }

    // MARK: - Clamping

    /// Return a nearby anchor whose *item* fits entirely inside `frame`.
    ///
    /// Only the visible item is clamped: the transparent shadow padding may
    /// extend past the screen edge. `frame` is expected to be the screen's
    /// `visibleFrame`, so the menu bar and Dock stay clear.
    static func clamp(
        anchor: CGPoint,
        style: DesktopRecordStyle,
        recordOut: Bool,
        to frame: CGRect
    ) -> CGPoint {
        // Display hot-plug can momentarily leave no usable screen. Returning
        // the original anchor keeps that transient from rewriting every record
        // to the origin.
        guard frame.width > 0, frame.height > 0 else { return anchor }

        let size = itemSize(for: style, recordOut: recordOut)
        let offset = anchorOffset(for: style, recordOut: recordOut)

        // The item's origin is `anchor - offset`; solve each axis so the item
        // stays inside the frame. When the frame is smaller than the item,
        // centre the item in that axis instead of oscillating between edges.
        let minX = frame.minX + offset.x
        let maxX = frame.maxX - size.width + offset.x
        let x: CGFloat
        if minX <= maxX {
            x = min(max(anchor.x, minX), maxX)
        } else {
            x = frame.midX - size.width / 2 + offset.x
        }

        let minY = frame.minY + offset.y
        let maxY = frame.maxY - size.height + offset.y
        let y: CGFloat
        if minY <= maxY {
            y = min(max(anchor.y, minY), maxY)
        } else {
            y = frame.midY - size.height / 2 + offset.y
        }

        return CGPoint(x: x, y: y)
    }

    /// Compatibility overload: clamps an item *centre* given its size.
    static func clamp(_ position: CGPoint, itemSize: CGSize, to frame: CGRect) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return position }

        let halfWidth = min(itemSize.width / 2, frame.width / 2)
        let halfHeight = min(itemSize.height / 2, frame.height / 2)
        return CGPoint(
            x: min(max(position.x, frame.minX + halfWidth), frame.maxX - halfWidth),
            y: min(max(position.y, frame.minY + halfHeight), frame.maxY - halfHeight)
        )
    }

    // MARK: - Default placement

    /// First package slot as an anchor: the cover/disc centre near the top
    /// centre, below the delete zone, with a short down-right cascade so
    /// repeated clicks do not stack exactly.
    static func defaultSlot(
        style: DesktopRecordStyle,
        recordOut: Bool,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        notchHeight: CGFloat,
        index: Int
    ) -> CGPoint {
        let topInset = notchHeight + 80 + 16
        let step = cascadeStep * CGFloat(index % cascadeCount)
        let height = itemSize(for: style, recordOut: recordOut).height
        let candidate = CGPoint(
            x: screenFrame.midX + step,
            y: screenFrame.maxY - topInset - height / 2 - step
        )
        return clamp(
            anchor: candidate,
            style: style,
            recordOut: recordOut,
            to: visibleFrame
        )
    }

    /// Compatibility overload that predates anchors. Callers pass the item
    /// size and receive an item-centre position, matching the old behaviour.
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

    // MARK: - Delete zone

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

    // MARK: - Screen identity

    /// Screen identity that survives a relaunch. Display IDs can change when
    /// cables are swapped, so callers must still fall back to the main screen.
    static func screenID(for screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return number.stringValue
    }
}
