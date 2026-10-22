import Foundation

/// Stable identifiers for every user-facing string.
///
/// Keys describe meaning, not copy, so translations can be reworded without
/// touching Swift code. Keep this list in sync with `en.json`; `--self-test`
/// fails when a key is missing.
enum LocalizationKey: String, CaseIterable {
    // MARK: Menu

    case menuEnable = "menu.enable"
    case menuDemo = "menu.demo"
    case menuGestureTips = "menu.gestureTips"
    case menuSkin = "menu.skin"
    case menuRetryMusic = "menu.retryMusic"
    case menuOpenMusic = "menu.openMusic"
    case menuAutomationSettings = "menu.automationSettings"
    case menuQuit = "menu.quit"

    // MARK: Skins

    case skinClassic = "skin.classic"
    case skinRust = "skin.rust"
    case skinTeal = "skin.teal"
    case skinSmoke = "skin.smoke"
    case skinMono = "skin.mono"

    // MARK: Status

    case statusNoDisplay = "status.noDisplay"
    case statusOverlayInactive = "status.overlayInactive"
    case statusDisabled = "status.disabled"
    case statusMusicNotRunning = "status.musicNotRunning"
    case statusNoTrack = "status.noTrack"
    case statusPermissionRequired = "status.permissionRequired"

    // MARK: Header and overlay

    case headerNoTrack = "header.noTrack"
    case overlayPullToLock = "overlay.pullToLock"

    // MARK: Gesture hint

    case hintClickTitle = "hint.click.title"
    case hintClickDetail = "hint.click.detail"
    case hintSwipeTitle = "hint.swipe.title"
    case hintSwipeDetail = "hint.swipe.detail"
    case hintPullTitle = "hint.pull.title"
    case hintPullDetail = "hint.pull.detail"

    // MARK: Permission alert

    case alertPermissionTitle = "alert.permissionTitle"
    case alertPermissionBody = "alert.permissionBody"
    case alertOpenSettings = "alert.openSettings"
    case alertLater = "alert.later"

    // MARK: Accessibility

    case a11yApp = "a11y.app"
    case a11yHeaderTitle = "a11y.headerTitle"
    case a11yHeaderTitleArtist = "a11y.headerTitleArtist"
    case a11yHeaderStatus = "a11y.headerStatus"

    // MARK: Info.plist (generated into InfoPlist.strings by build-app.sh)

    case infoAppleEventsUsageDescription = "info.appleEventsUsageDescription"
}
