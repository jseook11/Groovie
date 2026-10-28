import AppKit
import CoreGraphics

/// Where the overlay lives on a given display.
///
/// On a notched MacBook the record emerges from the bottom edge of the camera
/// housing. On a display without a notch the same geometry is used with the
/// screen's top edge as the emergence line, so the record center appears at the
/// edge exactly as it does on hardware with a notch.
struct NotchScreen {
    let screen: NSScreen
    /// The idle hover / input region at the top centre of the display.
    let notchRect: CGRect
    let notchWidth: CGFloat
    /// Height of that region (physical notch, or the menu bar on other displays).
    let notchHeight: CGFloat
    /// Distance from the screen's top edge to the line the record emerges from.
    let emergenceInset: CGFloat
    let hasPhysicalNotch: Bool

    static func current(
        preferredDisplayID: CGDirectDisplayID? = DisplayPreference.stored()
    ) -> NotchScreen? {
        // An explicitly chosen display wins even when it has no camera housing.
        if let preferredDisplayID,
           let screen = NSScreen.screens.first(where: { displayID(of: $0) == preferredDisplayID })
        {
            return forScreen(screen)
        }

        // Development aid: exercise the no-notch layout on a notched Mac.
        let simulateNoNotch = ProcessInfo.processInfo.arguments.contains("--simulate-no-notch")
        if !simulateNoNotch {
            let notched = NSScreen.screens.compactMap(notchedScreen(for:))
            if let best = notched.first(where: { isBuiltIn($0.screen) }) ?? notched.first {
                return best
            }
        }

        // No camera housing (external display, older Mac): emerge from the top edge.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return topEdgeScreen(for: screen)
    }

    /// The overlay geometry for a specific display, used by the idle surfaces
    /// on displays that do not host the record.
    static func forScreen(_ screen: NSScreen) -> NotchScreen {
        let simulateNoNotch = ProcessInfo.processInfo.arguments.contains("--simulate-no-notch")
        if !simulateNoNotch, let notched = notchedScreen(for: screen) {
            return notched
        }
        return topEdgeScreen(for: screen)
    }

    private static func notchedScreen(for screen: NSScreen) -> NotchScreen? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }

        let x0 = left.maxX
        let x1 = right.minX
        guard x1 > x0 + 80 else { return nil }

        let height = max(left.height, screen.safeAreaInsets.top)
        let rect = CGRect(
            x: x0,
            y: screen.frame.maxY - height,
            width: x1 - x0,
            height: height
        )
        return NotchScreen(
            screen: screen,
            notchRect: rect,
            notchWidth: rect.width,
            notchHeight: height,
            emergenceInset: height,
            hasPhysicalNotch: true
        )
    }

    private static func topEdgeScreen(for screen: NSScreen) -> NotchScreen {
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat = 179
        let rect = CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - menuBarHeight,
            width: width,
            height: menuBarHeight
        )
        return NotchScreen(
            screen: screen,
            notchRect: rect,
            notchWidth: width,
            notchHeight: menuBarHeight,
            emergenceInset: 0,
            hasPhysicalNotch: false
        )
    }

    /// The Core Graphics display ID backing an `NSScreen`.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(truncating: number)
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let id = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}

/// The display chosen from the status menu. `nil` means automatic: the
/// built-in notched display, otherwise the main screen.
enum DisplayPreference {
    static let defaultsKey = "umak.preferredDisplayID"

    static func stored(defaults: UserDefaults = .standard) -> CGDirectDisplayID? {
        guard let raw = defaults.object(forKey: defaultsKey) as? NSNumber else { return nil }
        return CGDirectDisplayID(truncating: raw)
    }

    static func persist(_ id: CGDirectDisplayID?, defaults: UserDefaults = .standard) {
        if let id {
            defaults.set(Int(id), forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The stored choice when that display is connected. A disconnected
    /// display falls back to automatic until it returns.
    static func available(defaults: UserDefaults = .standard) -> CGDirectDisplayID? {
        guard let stored = stored(defaults: defaults) else { return nil }
        return NSScreen.screens.contains(where: { NotchScreen.displayID(of: $0) == stored })
            ? stored
            : nil
    }
}

/// All window/content frames for the overlay, in AppKit screen coordinates.
struct StageGeometry {
    let screenFrame: CGRect
    let screenID: CGDirectDisplayID?
    let notchRect: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let emergenceInset: CGFloat
    let hasPhysicalNotch: Bool
    let windowWidth: CGFloat
    let windowHeight: CGFloat

    init(notch: NotchScreen, windowWidth: CGFloat = 300, windowHeight: CGFloat = 190) {
        self.screenFrame = notch.screen.frame
        self.screenID = NotchScreen.displayID(of: notch.screen)
        self.notchRect = notch.notchRect
        self.notchWidth = notch.notchWidth
        self.notchHeight = notch.notchHeight
        self.emergenceInset = notch.emergenceInset
        self.hasPhysicalNotch = notch.hasPhysicalNotch
        self.windowWidth = max(windowWidth, notch.notchWidth + 100)
        self.windowHeight = windowHeight
    }

    /// Idle: the whole camera housing plus a small margin. The pointer is hidden
    /// while it is over the notch, so the entire hidden area — and a few points
    /// around it — must accept clicks and scrolling.
    var idleFrame: CGRect {
        let horizontal: CGFloat = 6
        let downward: CGFloat = 6
        return CGRect(
            x: notchRect.minX - horizontal,
            y: notchRect.minY - downward,
            width: notchRect.width + horizontal * 2,
            height: notchRect.height + downward
        )
    }

    /// Active: the full stage, anchored to the top-centre of the screen. The top
    /// edge of the window is the top edge of the display in both cases.
    var expandedFrame: CGRect {
        CGRect(
            x: notchRect.midX - windowWidth / 2,
            y: screenFrame.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
    }

    var contentSize: CGSize {
        CGSize(width: windowWidth, height: windowHeight)
    }
}
