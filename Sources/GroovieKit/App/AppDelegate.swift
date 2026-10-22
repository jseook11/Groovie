import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var retained: AppDelegate?

    private var controller: OverlayController?
    private var music: MusicProviding?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuHeader: MenuHeaderView?
    private var isMenuOpen = false
    private var needsMenuRebuild = false
    private var enabled = true
    private var hasNotch = false
    private var currentNotch: NotchScreen?
    private let gestureHint = GestureHintPresenter()
    private var hintSchedule: DispatchWorkItem?
    private static let gestureHintShownKey = "groovie.gestureHintShown"
    private var permissionAlertShown = false
    private var screenObserver: NSObjectProtocol?

    /// Entry point used by the executable target.
    public static func run() {
        let delegate = AppDelegate()
        retained = delegate

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate

        // A minimal menu keeps standard editing shortcuts available for any
        // future text field without showing a Dock icon.
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        app.mainMenu = mainMenu

        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        refreshOverlaySetup()
        scheduleFirstRunHint()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshOverlaySetup() }
        }

        if ProcessInfo.processInfo.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.controller?.runDemo()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hintSchedule?.cancel()
        gestureHint.dismiss(animated: false)
        controller?.deactivate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    // MARK: - Overlay

    private func refreshOverlaySetup() {
        let notch = NotchScreen.current()
        hasNotch = notch != nil
        currentNotch = notch
        gestureHint.dismiss(animated: false)

        if let notch {
            if let controller {
                controller.rebuild(for: notch)
                if enabled { controller.activate() }
            } else {
                let demoMode = ProcessInfo.processInfo.arguments.contains("--fake-music")
                let provider: MusicProviding = demoMode ? DemoMusicService() : AppleMusicService()
                let controller = OverlayController(
                    geometry: StageGeometry(notch: notch),
                    music: provider
                )
                controller.onPermissionDenied = { [weak self] in
                    self?.showPermissionAlert()
                }
                controller.onStateChange = { [weak self] in
                    self?.rebuildMenu()
                }
                self.music = provider
                self.controller = controller
                if enabled { controller.activate() }
            }
        } else {
            controller?.deactivate()
            controller = nil
            music = nil
        }

        controller?.onInteractionStart = { [weak self] in
            self?.gestureHint.dismiss()
        }

        rebuildMenu()
    }

    /// Introduce the hidden strip on a display that has no physical notch to
    /// advertise it. Shown once per install; the status menu can replay it.
    /// A `--gesture-hint` launch argument forces it for development.
    private func scheduleFirstRunHint() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") { return }

        let forced = arguments.contains("--gesture-hint")
        guard forced || currentNotch?.hasPhysicalNotch == false else { return }
        guard forced || !UserDefaults.standard.bool(forKey: Self.gestureHintShownKey) else { return }

        hintSchedule?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showGestureHint(force: forced)
        }
        hintSchedule = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func showGestureHint(force: Bool) {
        guard enabled, let notch = currentNotch else { return }
        if !force, UserDefaults.standard.bool(forKey: Self.gestureHintShownKey) { return }
        UserDefaults.standard.set(true, forKey: Self.gestureHintShownKey)
        gestureHint.show(on: notch)
    }

    private func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if newValue {
            controller?.activate()
        } else {
            hintSchedule?.cancel()
            gestureHint.dismiss(animated: false)
            controller?.deactivate()
        }
        rebuildMenu()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        // The brand mark is 20 x 11 pt; a fixed 24 pt slot keeps the menu bar
        // from shifting as the mark is tinted or the menu state changes.
        let item = NSStatusBar.system.statusItem(withLength: 24)
        if let button = item.button {
            button.image = BrandMark.menuBar
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = L10n.t(.a11yApp)
            button.setAccessibilityLabel(L10n.t(.a11yApp))
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        // Replacing the status item's menu while it is open can detach the
        // header view. Defer structural changes until the menu closes; the
        // header itself is updated in place.
        if isMenuOpen {
            updateMenuHeader()
            needsMenuRebuild = true
            return
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Each menu gets its own header view. Reusing one view across menu
        // instances lets AppKit reparent it and can leave the visible menu's
        // item with a detached view.
        let header = MenuHeaderView()
        let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerItem.view = header
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menuHeader = header

        menu.addItem(.separator())

        let enableItem = NSMenuItem(title: L10n.t(.menuEnable), action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        enableItem.isEnabled = hasNotch
        enableItem.state = enabled ? .on : .off
        menu.addItem(enableItem)

        let demoItem = NSMenuItem(title: L10n.t(.menuDemo), action: #selector(runDemo), keyEquivalent: "")
        demoItem.target = self
        demoItem.isEnabled = hasNotch && enabled
        menu.addItem(demoItem)

        let hintItem = NSMenuItem(title: L10n.t(.menuGestureTips), action: #selector(showGestureTips), keyEquivalent: "")
        hintItem.target = self
        hintItem.isEnabled = hasNotch && enabled
        menu.addItem(hintItem)

        let skinItem = NSMenuItem(title: L10n.t(.menuSkin), action: nil, keyEquivalent: "")
        let skinMenu = NSMenu()
        skinMenu.autoenablesItems = false
        for skin in VinylSkin.all {
            let item = NSMenuItem(title: L10n.t(skin.nameKey), action: #selector(selectSkin(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = skin.id
            item.isEnabled = hasNotch && enabled && controller != nil
            item.state = controller?.model.skinID == skin.id ? .on : .off
            skinMenu.addItem(item)
        }
        skinItem.submenu = skinMenu
        skinItem.isEnabled = hasNotch && enabled
        menu.addItem(skinItem)

        menu.addItem(.separator())

        let retryItem = NSMenuItem(title: L10n.t(.menuRetryMusic), action: #selector(retryMusic), keyEquivalent: "")
        retryItem.target = self
        retryItem.isEnabled = hasNotch && enabled
        menu.addItem(retryItem)

        let musicItem = NSMenuItem(title: L10n.t(.menuOpenMusic), action: #selector(openMusic), keyEquivalent: "")
        musicItem.target = self
        menu.addItem(musicItem)

        let automationItem = NSMenuItem(
            title: L10n.t(.menuAutomationSettings),
            action: #selector(openAutomationSettings),
            keyEquivalent: ""
        )
        automationItem.target = self
        menu.addItem(automationItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L10n.t(.menuQuit), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        statusItem?.menu = menu
        updateMenuHeader()
    }

    /// The header owns the song title, artist, and progress. Playback state is
    /// deliberately not repeated as text; only actionable availability problems
    /// replace the track rows.
    private func updateMenuHeader() {
        guard let menuHeader else { return }

        guard hasNotch else {
            menuHeader.setStatus(L10n.t(.statusNoDisplay))
            return
        }
        guard let controller else {
            menuHeader.setStatus(L10n.t(.statusOverlayInactive))
            return
        }
        let model = controller.model
        guard model.isEnabled else {
            menuHeader.setStatus(L10n.t(.statusDisabled))
            return
        }

        switch model.availability {
        case .appNotRunning:
            menuHeader.setStatus(L10n.t(.statusMusicNotRunning))
        case .noTrack:
            menuHeader.setStatus(L10n.t(.statusNoTrack))
        case .permissionDenied:
            menuHeader.setStatus(L10n.t(.statusPermissionRequired), warning: true)
        case .playing, .paused:
            let snapshot = controller.playbackSnapshot()
            menuHeader.setContent(
                title: model.trackTitle,
                artist: model.trackArtist,
                position: snapshot.position,
                duration: snapshot.duration,
                isPlaying: model.isPlaying
            )
        }
    }

    // MARK: - NSMenuDelegate

    public func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        // Refresh the position right before the menu appears so the progress
        // line starts from the current playback time.
        updateMenuHeader()
        menuHeader?.setActive(true)
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        menuHeader?.setActive(false)
        if needsMenuRebuild {
            needsMenuRebuild = false
            buildMenu()
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        setEnabled(!enabled)
    }

    @objc private func retryMusic() {
        controller?.refreshMusic()
    }

    @objc private func runDemo() {
        controller?.runDemo()
    }

    @objc private func showGestureTips() {
        showGestureHint(force: true)
    }

    @objc private func selectSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller?.selectSkin(id)
        rebuildMenu()
    }

    @objc private func openMusic() {
        let url = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    @objc private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showPermissionAlert() {
        guard !permissionAlertShown else { return }
        permissionAlertShown = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.alertPermissionTitle)
        alert.informativeText = L10n.t(.alertPermissionBody)
        alert.addButton(withTitle: L10n.t(.alertOpenSettings))
        alert.addButton(withTitle: L10n.t(.alertLater))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAutomationSettings()
        }
    }
}
