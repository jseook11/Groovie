import AppKit

/// A complete material for the record. Skins change the vinyl only; the label
/// still follows the track — artwork first, then a colour derived from the track.
struct VinylSkin: Identifiable, Equatable {
    let id: String
    let nameKey: LocalizationKey
    let recordCenter: NSColor
    let recordEdge: NSColor
    let grooveLight: NSColor
    let grooveDark: NSColor
    let sheen: NSColor
    let sheenStrength: CGFloat
    /// 1 keeps the track accent as-is; lower values pull it toward grey.
    let accentSaturation: CGFloat

    static let defaultsKey = "groovie.skinID"
    static let defaultID = "classic"

    static let classic = VinylSkin(
        id: "classic",
        nameKey: .skinClassic,
        recordCenter: NSColor(srgbRed: 0.102, green: 0.110, blue: 0.133, alpha: 1),
        recordEdge: NSColor(srgbRed: 0.051, green: 0.055, blue: 0.067, alpha: 1),
        grooveLight: .white,
        grooveDark: .black,
        sheen: .white,
        sheenStrength: 1,
        accentSaturation: 1
    )

    static let rust = VinylSkin(
        id: "rust",
        nameKey: .skinRust,
        recordCenter: NSColor(srgbRed: 0.200, green: 0.106, blue: 0.082, alpha: 1),
        recordEdge: NSColor(srgbRed: 0.102, green: 0.051, blue: 0.039, alpha: 1),
        grooveLight: NSColor(srgbRed: 1.000, green: 0.870, blue: 0.790, alpha: 1),
        grooveDark: .black,
        sheen: NSColor(srgbRed: 1.000, green: 0.850, blue: 0.720, alpha: 1),
        sheenStrength: 1.05,
        accentSaturation: 1
    )

    static let teal = VinylSkin(
        id: "teal",
        nameKey: .skinTeal,
        recordCenter: NSColor(srgbRed: 0.063, green: 0.165, blue: 0.165, alpha: 1),
        recordEdge: NSColor(srgbRed: 0.031, green: 0.086, blue: 0.086, alpha: 1),
        grooveLight: NSColor(srgbRed: 0.780, green: 0.950, blue: 0.930, alpha: 1),
        grooveDark: .black,
        sheen: NSColor(srgbRed: 0.720, green: 0.960, blue: 0.930, alpha: 1),
        sheenStrength: 1.05,
        accentSaturation: 1
    )

    static let smoke = VinylSkin(
        id: "smoke",
        nameKey: .skinSmoke,
        recordCenter: NSColor(srgbRed: 0.157, green: 0.169, blue: 0.192, alpha: 1),
        recordEdge: NSColor(srgbRed: 0.071, green: 0.078, blue: 0.094, alpha: 1),
        grooveLight: NSColor(srgbRed: 0.880, green: 0.920, blue: 1.000, alpha: 1),
        grooveDark: .black,
        sheen: NSColor(srgbRed: 0.870, green: 0.910, blue: 0.980, alpha: 1),
        sheenStrength: 0.92,
        accentSaturation: 1
    )

    static let mono = VinylSkin(
        id: "mono",
        nameKey: .skinMono,
        recordCenter: NSColor(srgbRed: 0.106, green: 0.114, blue: 0.129, alpha: 1),
        recordEdge: NSColor(srgbRed: 0.047, green: 0.051, blue: 0.059, alpha: 1),
        grooveLight: .white,
        grooveDark: .black,
        sheen: .white,
        sheenStrength: 1.12,
        accentSaturation: 0.25
    )

    static let all: [VinylSkin] = [classic, rust, teal, smoke, mono]

    static func skin(id: String) -> VinylSkin {
        all.first(where: { $0.id == id }) ?? classic
    }

    /// The last chosen skin, or the default when the stored value is unknown.
    static var storedID: String {
        let id = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return skin(id: id).id
    }

    /// Initial skin for this launch. `--skin=<id>` overrides the saved choice for
    /// screenshots and development without changing the saved preference.
    static var launchID: String {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--skin=") {
            let id = String(argument.dropFirst("--skin=".count))
            if all.contains(where: { $0.id == id }) { return id }
        }
        return storedID
    }

    static func persist(id: String) {
        UserDefaults.standard.set(skin(id: id).id, forKey: defaultsKey)
    }

    static func == (lhs: VinylSkin, rhs: VinylSkin) -> Bool {
        lhs.id == rhs.id
    }

    /// Label colour for a track. Artwork still wins at the call site; this is the
    /// printed-paper fallback and keeps a per-track colour.
    func labelAccent(for seed: String) -> NSColor {
        let base = VinylTheme.accent(for: seed)
        guard accentSaturation < 0.999,
              let rgb = base.usingColorSpace(.sRGB)
        else { return base }

        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        let colour = accentSaturation
        let grey = 1 - colour
        return NSColor(
            srgbRed: rgb.redComponent * colour + luminance * grey,
            green: rgb.greenComponent * colour + luminance * grey,
            blue: rgb.blueComponent * colour + luminance * grey,
            alpha: 1
        )
    }
}
