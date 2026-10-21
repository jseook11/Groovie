import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retained: AppDelegate?

    private var controller: OverlayController?
    private var music: MusicProviding?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var enabled = true
    private var hasNotch = false
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

        rebuildMenu()
    }

    private func setEnabled(_ newValue: Bool) {
        enabled = newValue
        if newValue {
            controller?.activate()
        } else {
            controller?.deactivate()
        }
        rebuildMenu()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "Notch Vinyl")
                ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Notch Vinyl")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Notch Vinyl"
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: "Notch Vinyl", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        if !hasNotch {
            let missing = NSMenuItem(title: "사용 가능한 디스플레이를 찾을 수 없습니다", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        } else {
            let status = NSMenuItem(title: musicStatusText, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())

        let enableItem = NSMenuItem(title: "활성화", action: #selector(toggleEnabled), keyEquivalent: "")
        enableItem.target = self
        enableItem.isEnabled = hasNotch
        enableItem.state = enabled ? .on : .off
        menu.addItem(enableItem)

        let demoItem = NSMenuItem(title: "데모 재생", action: #selector(runDemo), keyEquivalent: "")
        demoItem.target = self
        demoItem.isEnabled = hasNotch && enabled
        menu.addItem(demoItem)

        menu.addItem(.separator())

        let retryItem = NSMenuItem(title: "Music 연결 다시 시도", action: #selector(retryMusic), keyEquivalent: "")
        retryItem.target = self
        retryItem.isEnabled = hasNotch && enabled
        menu.addItem(retryItem)

        let musicItem = NSMenuItem(title: "Music 열기", action: #selector(openMusic), keyEquivalent: "")
        musicItem.target = self
        menu.addItem(musicItem)

        let automationItem = NSMenuItem(
            title: "자동화 권한 설정…",
            action: #selector(openAutomationSettings),
            keyEquivalent: ""
        )
        automationItem.target = self
        menu.addItem(automationItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Notch Vinyl 종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.menu = menu
        statusItem?.menu = menu
    }

    private var musicStatusText: String {
        guard let controller else { return "오버레이 비활성" }
        let model = controller.model
        guard model.isEnabled else { return "비활성화됨" }
        switch model.availability {
        case .appNotRunning:
            return "Music이 실행 중이 아닙니다"
        case .noTrack:
            return "Music에 재생할 트랙이 없습니다"
        case .paused:
            return "Music 일시정지 · 스크럽 가능"
        case .playing:
            let title = model.trackTitle
            return title.isEmpty ? "Music 재생 중" : "Music 재생 중 · \(title)"
        case .permissionDenied:
            return "자동화 권한이 필요합니다"
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
        alert.messageText = "Notch Vinyl이 Music을 제어할 수 없습니다"
        alert.informativeText = """
        시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 \
        Notch Vinyl이 Music을 제어하도록 허용해 주세요.
        """
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "나중에")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAutomationSettings()
        }
    }
}
