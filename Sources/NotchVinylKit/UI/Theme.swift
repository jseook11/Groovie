import AppKit
import SwiftUI

enum VinylTheme {
    static let recordBase = Color(red: 0.038, green: 0.038, blue: 0.043)
    static let recordBaseNS = NSColor(srgbRed: 0.038, green: 0.038, blue: 0.043, alpha: 1)
    static let hardwareBlack = Color.black

    static let accentColors: [NSColor] = [
        NSColor(srgbRed: 0.70, green: 0.33, blue: 0.24, alpha: 1), // rust
        NSColor(srgbRed: 0.25, green: 0.43, blue: 0.42, alpha: 1), // teal
        NSColor(srgbRed: 0.78, green: 0.60, blue: 0.26, alpha: 1), // mustard
        NSColor(srgbRed: 0.28, green: 0.33, blue: 0.43, alpha: 1), // slate
        NSColor(srgbRed: 0.44, green: 0.29, blue: 0.37, alpha: 1), // plum
    ]

    static let labelCream = NSColor(srgbRed: 0.92, green: 0.88, blue: 0.79, alpha: 1)
    static let labelInk = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.09, alpha: 1)

    static func accent(for seed: String) -> NSColor {
        var hash: UInt32 = 2166136261
        for byte in seed.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return accentColors[Int(hash % UInt32(accentColors.count))]
    }
}
