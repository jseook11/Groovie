import AppKit

/// Fixed-width header for the status menu.
///
/// The track title scrolls inside a clipped column when it does not fit. The
/// artist is truncated, and playback state is deliberately not shown as text;
/// a thin progress line carries the useful part of that information instead.
final class MenuHeaderView: NSView {
    static let contentWidth: CGFloat = 252
    static let contentHeight: CGFloat = 56

    private let logoView = BrandMarkView()
    private let titleClip = NSView()
    private let titleContent = NSView()
    private let titleLabel = MenuHeaderView.makeLabel(size: 13, weight: .semibold, color: .labelColor)
    private let titleEcho = MenuHeaderView.makeLabel(size: 13, weight: .semibold, color: .labelColor)
    private let artistLabel = MenuHeaderView.makeLabel(size: 11, weight: .regular, color: .secondaryLabelColor)
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private let warningDot = NSView()

    private var marqueeTimer: Timer?
    private var progressTimer: Timer?
    private var marqueeStart: TimeInterval = 0
    private var marqueeTextWidth: CGFloat = 0
    private let marqueeSpeed: CGFloat = 20
    private let marqueeGap: CGFloat = 28
    private let marqueeHold: TimeInterval = 0.7

    private var basePosition: Double = 0
    private var trackDuration: Double = 0
    private var isPlaying = false
    private var isStatusMode = false
    private var sampledAt: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.contentWidth,
            height: Self.contentHeight
        ))
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.contentWidth, height: Self.contentHeight)
    }

    deinit {
        marqueeTimer?.invalidate()
        progressTimer?.invalidate()
    }

    // MARK: - Content

    /// Show a track. `position` and `duration` are sampled at menu-open time;
    /// the header advances the line locally while the menu stays open.
    func setContent(
        title: String,
        artist: String,
        position: Double,
        duration: Double,
        isPlaying: Bool
    ) {
        let text = title.isEmpty ? "재생 중인 곡 없음" : title
        let secondary = title.isEmpty
        isStatusMode = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = secondary ? .secondaryLabelColor : .labelColor
        titleLabel.stringValue = text
        titleEcho.font = titleLabel.font
        titleEcho.textColor = titleLabel.textColor
        titleEcho.stringValue = text

        artistLabel.stringValue = artist
        artistLabel.isHidden = false
        warningDot.isHidden = true
        titleClip.frame = NSRect(x: 50, y: 9, width: 188, height: 17)

        basePosition = position
        trackDuration = duration
        self.isPlaying = isPlaying
        sampledAt = ProcessInfo.processInfo.systemUptime

        progressTrack.isHidden = duration <= 0
        progressFill.isHidden = duration <= 0
        updateProgress()

        setAccessibilityLabel(accessibilityText(title: text, artist: artist))
        layoutTitle(reset: true)
    }

    /// Replace the track rows with an actionable status message.
    func setStatus(_ text: String, warning: Bool = false) {
        isStatusMode = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = text
        titleEcho.stringValue = ""
        titleEcho.isHidden = true
        artistLabel.isHidden = true
        progressTrack.isHidden = true
        progressFill.isHidden = true
        warningDot.isHidden = !warning

        let inset: CGFloat = warning ? 10 : 0
        titleClip.frame = NSRect(x: 50 + inset, y: 17, width: 188 - inset, height: 17)
        basePosition = 0
        trackDuration = 0
        isPlaying = false
        setAccessibilityLabel("Groovie, \(text)")
        layoutTitle(reset: true)
        stopTimers()
    }

    /// Start or stop animation while the menu is on screen.
    func setActive(_ active: Bool) {
        if active {
            layoutTitle(reset: true)
            startTimers()
        } else {
            stopTimers()
            titleContent.frame.origin.x = 0
        }
    }

    // MARK: - Layout

    private func setUp() {
        logoView.frame = NSRect(x: 19, y: (Self.contentHeight - 11) / 2, width: 20, height: 11)
        addSubview(logoView)

        titleClip.frame = NSRect(x: 50, y: 9, width: 188, height: 17)
        titleClip.wantsLayer = true
        titleClip.layer?.masksToBounds = true
        addSubview(titleClip)

        titleContent.addSubview(titleLabel)
        titleContent.addSubview(titleEcho)
        titleClip.addSubview(titleContent)

        artistLabel.frame = NSRect(x: 50, y: 26, width: 188, height: 15)
        addSubview(artistLabel)

        progressTrack.frame = NSRect(x: 50, y: 46, width: 188, height: 2)
        progressTrack.wantsLayer = true
        progressTrack.layer?.cornerRadius = 1
        addSubview(progressTrack)

        progressFill.frame = NSRect(x: 50, y: 46, width: 0, height: 2)
        progressFill.wantsLayer = true
        progressFill.layer?.cornerRadius = 1
        addSubview(progressFill)
        refreshLayerColors()

        warningDot.frame = NSRect(x: 50, y: 24, width: 4, height: 4)
        warningDot.wantsLayer = true
        warningDot.layer?.backgroundColor = NSColor(
            srgbRed: 0.70, green: 0.33, blue: 0.24, alpha: 1
        ).cgColor
        warningDot.layer?.cornerRadius = 2
        warningDot.isHidden = true
        addSubview(warningDot)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Groovie")
        for child in [logoView, titleClip, titleLabel, titleEcho, artistLabel, progressTrack, progressFill, warningDot] {
            child.setAccessibilityElement(false)
        }
    }

    private func refreshLayerColors() {
        progressTrack.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        progressFill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
    }

    private static func makeLabel(
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    private func layoutTitle(reset: Bool) {
        let text = titleLabel.stringValue
        let font = titleLabel.font ?? .systemFont(ofSize: 13, weight: .semibold)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        marqueeTextWidth = width

        let clipWidth = titleClip.bounds.width
        titleLabel.toolTip = text
        titleLabel.frame = NSRect(x: 0, y: 0, width: width + 1, height: titleClip.bounds.height)
        titleEcho.frame = NSRect(
            x: width + marqueeGap,
            y: 0,
            width: width + 1,
            height: titleClip.bounds.height
        )

        let fits = width <= clipWidth
        if fits || reduceMotion || isStatusMode {
            titleLabel.lineBreakMode = .byTruncatingMiddle
            titleLabel.sizeToFit()
            titleLabel.frame = NSRect(
                x: 0,
                y: (titleClip.bounds.height - titleLabel.frame.height) / 2,
                width: clipWidth,
                height: titleLabel.frame.height
            )
            titleEcho.isHidden = true
            titleContent.frame = NSRect(x: 0, y: 0, width: clipWidth, height: titleClip.bounds.height)
            marqueeTextWidth = 0
            stopMarquee()
        } else {
            titleLabel.lineBreakMode = .byClipping
            titleEcho.isHidden = false
            titleContent.frame = NSRect(
                x: 0,
                y: 0,
                width: width * 2 + marqueeGap,
                height: titleClip.bounds.height
            )
            if reset {
                marqueeStart = ProcessInfo.processInfo.systemUptime
                titleContent.frame.origin.x = 0
            }
        }
    }

    // MARK: - Timers

    private func startTimers() {
        startMarqueeIfNeeded()
        startProgressIfNeeded()
    }

    private func stopTimers() {
        stopMarquee()
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func startMarqueeIfNeeded() {
        guard !isStatusMode,
              marqueeTextWidth > titleClip.bounds.width,
              !reduceMotion
        else {
            stopMarquee()
            return
        }
        guard marqueeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepMarquee()
        }
        RunLoop.main.add(timer, forMode: .common)
        marqueeTimer = timer
    }

    private func stopMarquee() {
        marqueeTimer?.invalidate()
        marqueeTimer = nil
        titleContent.frame.origin.x = 0
    }

    private func stepMarquee() {
        let distance = marqueeTextWidth + marqueeGap
        guard distance > 0 else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - marqueeStart
        guard elapsed > marqueeHold else { return }
        let travel = CGFloat(elapsed - marqueeHold) * marqueeSpeed
        titleContent.frame.origin.x = -travel.truncatingRemainder(dividingBy: distance)
    }

    private func startProgressIfNeeded() {
        guard trackDuration > 0, progressTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func updateProgress() {
        guard trackDuration > 0 else { return }
        let elapsed = isPlaying ? max(0, ProcessInfo.processInfo.systemUptime - sampledAt) : 0
        let current = min(max(basePosition + elapsed, 0), trackDuration)
        let fraction = CGFloat(current / trackDuration)
        progressFill.frame.size.width = progressTrack.bounds.width * fraction
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func accessibilityText(title: String, artist: String) -> String {
        artist.isEmpty ? "Groovie, \(title)" : "Groovie, \(title), \(artist)"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayerColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimers()
        } else {
            refreshLayerColors()
        }
    }
}
