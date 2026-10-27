import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static var retained: AppDelegate?

    private var controller: OverlayController?
    private var music: MusicProviding?
    private var playerCoordinator: PlayerCoordinator?
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
    private static let gestureHintShownKey = "umak.gestureHintShown"
    private var permissionAlertsShown: Set<PlayerID> = []
    private var screenObserver: NSObjectProtocol?
    private let updateChecker = UpdateChecker()
    private var availableUpdate: UpdateChecker.Release?
    private var isCheckingUpdates = false
    private var desktopRecords: DesktopRecordController?

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
        // Desktop decorations are independent of Music and of the notch.
        // `--desktop-demo` uses a throwaway store so the layer can be inspected
        // without touching the user's saved items.
        let isDesktopDemo = ProcessInfo.processInfo.arguments.contains("--desktop-demo")
        let demoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UmakDesktopDemo", isDirectory: true)
        if isDesktopDemo {
            try? FileManager.default.removeItem(at: demoDirectory)
        }
        let demoStore = isDesktopDemo
            ? DesktopRecordStore(baseDirectory: demoDirectory)
            : nil
        let records = DesktopRecordController(store: demoStore)
        records.onRecordsChanged = { [weak self] in self?.rebuildMenu() }
        desktopRecords = records

        // Bring the menu bar up before restoring decorations. The controller
        // spreads restore across run-loop turns, so a large desktop cannot
        // delay the app's first usable frame.
        setUpStatusItem()
        refreshOverlaySetup()
        records.start()
        if isDesktopDemo {
            seedDesktopDemo(records)
        }
        scheduleFirstRunHint()
        startUpdateCheck()

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
        desktopRecords?.stop()
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
        desktopRecords?.updateGeometry(notch.map { StageGeometry(notch: $0) })

        if let notch {
            if let controller {
                controller.rebuild(for: notch)
                if enabled { controller.activate() }
            } else {
                let demoMode = ProcessInfo.processInfo.arguments.contains("--fake-music")
                let provider: MusicProviding
                if demoMode {
                    provider = DemoMusicService()
                    playerCoordinator = nil
                } else {
                    let coordinator = PlayerCoordinator()
                    playerCoordinator = coordinator
                    provider = coordinator
                }
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
            playerCoordinator = nil
        }

        controller?.onInteractionStart = { [weak self] in
            self?.gestureHint.dismiss()
        }
        controller?.desktopRecords = desktopRecords

        rebuildMenu()
    }

    /// Development aid: `--desktop-demo --fake-music` seeds one disc and one
    /// packaged album in a throwaway store so the desktop layer can be checked
    /// without a Music library or a manual Option drag.
    private func seedDesktopDemo(_ controller: DesktopRecordController) {
        guard controller.recordCount == 0, let screen = NSScreen.main else { return }
        let snapshot = TrackSnapshot(
            persistentID: "demo-desktop",
            title: "Blue in Green",
            artist: "Miles Davis",
            album: "Kind of Blue",
            duration: 337
        )
        let visible = screen.visibleFrame
        let disc = controller.createRecord(
            snapshot: snapshot,
            artwork: nil,
            style: .disc,
            at: CGPoint(x: visible.midX - 170, y: visible.midY + 80)
        )
        _ = controller.createRecord(
            snapshot: snapshot,
            artwork: nil,
            style: .sleeve,
            at: CGPoint(x: visible.midX + 90, y: visible.midY + 80)
        )

        // `--desktop-demo-toggle` exercises the same path as an Option-click
        // without needing a visible desktop or a synthetic mouse event.
        if ProcessInfo.processInfo.arguments.contains("--desktop-demo-toggle"),
           let disc
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.toggleStyle(id: disc.id)
            }
        }
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
        desktopRecords?.setActive(newValue)
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

        let playerItem = NSMenuItem(title: L10n.t(.menuPlayer), action: nil, keyEquivalent: "")
        let playerMenu = NSMenu()
        playerMenu.autoenablesItems = false
        let playerChoices: [(PlayerPreference, LocalizationKey)] = [
            (.auto, .playerAuto),
            (.music, .playerMusic),
            (.spotify, .playerSpotify),
        ]
        for (preference, key) in playerChoices {
            let item = NSMenuItem(
                title: L10n.t(key),
                action: #selector(selectPlayer(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preference.rawValue
            let installed = preference.playerID?.isInstalled ?? true
            item.isEnabled = hasNotch
                && enabled
                && controller != nil
                && playerCoordinator != nil
                && installed
            item.state = playerCoordinator?.preference == preference ? .on : .off
            playerMenu.addItem(item)
        }
        playerItem.submenu = playerMenu
        playerItem.isEnabled = hasNotch && enabled && playerCoordinator != nil
        menu.addItem(playerItem)

        let clearDesktopItem = NSMenuItem(
            title: L10n.t(.menuClearDesktopRecords, desktopRecords?.recordCount ?? 0),
            action: #selector(clearDesktopRecords),
            keyEquivalent: ""
        )
        clearDesktopItem.target = self
        clearDesktopItem.isEnabled = enabled && (desktopRecords?.recordCount ?? 0) > 0
        menu.addItem(clearDesktopItem)

        menu.addItem(.separator())

        let retryItem = NSMenuItem(
            title: L10n.t(.menuRetryPlayer, activePlayerName),
            action: #selector(retryPlayer),
            keyEquivalent: ""
        )
        retryItem.target = self
        retryItem.isEnabled = hasNotch
            && enabled
            && playerCoordinator != nil
            && (playerCoordinator?.activePlayerIsInstalled ?? true)
        menu.addItem(retryItem)

        let playerOpenItem = NSMenuItem(
            title: L10n.t(.menuOpenPlayer, activePlayerName),
            action: #selector(openPlayer),
            keyEquivalent: ""
        )
        playerOpenItem.target = self
        playerOpenItem.isEnabled = hasNotch
            && enabled
            && playerCoordinator != nil
            && (playerCoordinator?.activePlayerIsInstalled ?? true)
        menu.addItem(playerOpenItem)

        let automationItem = NSMenuItem(
            title: L10n.t(.menuAutomationSettings),
            action: #selector(openAutomationSettings),
            keyEquivalent: ""
        )
        automationItem.target = self
        menu.addItem(automationItem)

        let updateItem: NSMenuItem
        if isCheckingUpdates {
            updateItem = NSMenuItem(title: L10n.t(.menuCheckingUpdates), action: nil, keyEquivalent: "")
            updateItem.isEnabled = false
        } else if let update = availableUpdate {
            updateItem = NSMenuItem(
                title: L10n.t(.menuUpdateAvailable, update.version),
                action: #selector(openAvailableUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
        } else {
            updateItem = NSMenuItem(
                title: L10n.t(.menuCheckUpdates),
                action: #selector(checkForUpdatesNow),
                keyEquivalent: ""
            )
            updateItem.target = self
        }
        menu.addItem(updateItem)

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
            menuHeader.setStatus(L10n.t(.statusPlayerNotRunning, activePlayerName))
        case .noTrack:
            menuHeader.setStatus(L10n.t(.statusNoTrack))
        case .permissionDenied:
            menuHeader.setStatus(
                L10n.t(.statusPermissionRequired, activePlayerName),
                warning: true
            )
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

    /// The player the menu names in status and prompts. Before the overlay
    /// exists (or in demo mode) there is no coordinator, so Music is the
    /// sensible default.
    private var activePlayerName: String {
        playerCoordinator?.activePlayerName ?? PlayerID.music.displayName
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

    @objc private func retryPlayer() {
        // An explicit retry is a new permission attempt; allow the alert for
        // the player to appear again if access is still denied.
        permissionAlertsShown.removeAll()
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
        desktopRecords?.refreshSkins(VinylSkin.skin(id: id))
        rebuildMenu()
    }

    @objc private func clearDesktopRecords() {
        guard let desktopRecords, desktopRecords.recordCount > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.alertClearDesktopRecordsTitle)
        alert.informativeText = L10n.t(
            .alertClearDesktopRecordsBody,
            desktopRecords.recordCount
        )
        alert.addButton(withTitle: L10n.t(.alertClear))
        alert.addButton(withTitle: L10n.t(.alertLater))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            desktopRecords.deleteAll()
            rebuildMenu()
        }
    }

    @objc private func openPlayer() {
        music?.presentPlayer()
    }

    @objc private func selectPlayer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = PlayerPreference(rawValue: raw)
        else { return }
        // Choosing the already-selected player is a natural "try again" after
        // granting Automation access.
        if playerCoordinator?.preference == preference {
            retryPlayer()
            return
        }
        permissionAlertsShown.removeAll()
        playerCoordinator?.setPreference(preference)
        rebuildMenu()
    }

    @objc private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Updates

    /// The version shown to the user and reported to the release feed. When
    /// the executable runs outside an `.app` there is no Info.plist, so manual
    /// checks fall back to zero and automatic checks are skipped.
    private var currentVersion: String {
        UpdateChecker.bundledVersion() ?? "0.0.0"
    }

    private func startUpdateCheck() {
        availableUpdate = updateChecker.cachedUpdate(currentVersion: currentVersion)
        rebuildMenu()

        let arguments = ProcessInfo.processInfo.arguments
        let forced = arguments.contains("--check-updates")
        let canCheckAutomatically = UpdateChecker.bundledVersion() != nil
            && updateChecker.shouldCheckAutomatically()
        guard forced || canCheckAutomatically else { return }

        Task { [weak self] in
            guard let self else { return }
            if !forced {
                // Let the overlay and Music bridge settle before touching the
                // network; the result only affects the status menu.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            await self.checkForUpdates(manual: forced)
        }
    }

    private func checkForUpdates(manual: Bool) async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        rebuildMenu()

        let version = currentVersion
        let outcome = await updateChecker.check(currentVersion: version, force: manual)
        isCheckingUpdates = false

        switch outcome {
        case .available(_, let release):
            availableUpdate = release
            if manual { presentUpdateAlert(release, current: version) }
        case .upToDate:
            availableUpdate = nil
            if manual { presentUpToDateAlert(version: version) }
        case .failed:
            // Keep any update found on a previous launch; a failed background
            // check must not erase the menu entry.
            availableUpdate = updateChecker.cachedUpdate(currentVersion: version)
            if manual { presentUpdateCheckFailedAlert() }
        }
        rebuildMenu()
    }

    @objc private func checkForUpdatesNow() {
        Task { await checkForUpdates(manual: true) }
    }

    @objc private func openAvailableUpdate() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.pageURL)
    }

    private func presentUpdateAlert(_ release: UpdateChecker.Release, current: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.t(.alertUpdateTitle)
        alert.informativeText = L10n.t(.alertUpdateBody, release.version, current)
        alert.addButton(withTitle: L10n.t(.alertOpenRelease))
        alert.addButton(withTitle: L10n.t(.alertLater))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func presentUpToDateAlert(version: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.t(.alertUpToDateTitle)
        alert.informativeText = L10n.t(.alertUpToDateBody, version)
        alert.addButton(withTitle: L10n.t(.alertOK))

        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    private func presentUpdateCheckFailedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.alertUpdateFailedTitle)
        alert.informativeText = L10n.t(.alertUpdateFailedBody)
        alert.addButton(withTitle: L10n.t(.alertOK))

        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    private func showPermissionAlert() {
        let playerID = playerCoordinator?.activePlayerID ?? .music
        guard !permissionAlertsShown.contains(playerID) else { return }
        permissionAlertsShown.insert(playerID)

        let playerName = playerCoordinator?.activePlayerName ?? playerID.displayName
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.alertPermissionTitle, playerName)
        alert.informativeText = L10n.t(.alertPermissionBody, playerName)
        alert.addButton(withTitle: L10n.t(.alertOpenSettings))
        alert.addButton(withTitle: L10n.t(.alertLater))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAutomationSettings()
        }
    }
}
