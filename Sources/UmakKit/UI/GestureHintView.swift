import AppKit
import SwiftUI

/// A small, mouse-transparent coach mark that introduces the gestures hidden in
/// the notch. It appears once on displays without a camera housing, where there
/// is no physical shape to advertise the interaction area, and can be replayed
/// from the status menu.
struct GestureHintView: View {
    var body: some View {
        VStack(spacing: -1) {
            HintCaret()
                .fill(Color.black.opacity(0.74))
                .frame(width: 14, height: 6)

            HStack(spacing: 0) {
                item(
                    symbol: "cursorarrow.click",
                    title: L10n.t(.hintClickTitle),
                    detail: L10n.t(.hintClickDetail)
                )
                separator
                item(
                    symbol: "arrow.left.arrow.right",
                    title: L10n.t(.hintSwipeTitle),
                    detail: L10n.t(.hintSwipeDetail)
                )
                separator
                item(
                    symbol: "arrow.down",
                    title: L10n.t(.hintPullTitle),
                    detail: L10n.t(.hintPullDetail)
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.black.opacity(0.74))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5)
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .compositingGroup()
    }

    private func item(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 12)
    }
}

private struct HintCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Owns the hint's floating panel. The panel ignores mouse events entirely, so
/// the hint never competes with the notch's own click and scroll handling.
@MainActor
final class GestureHintPresenter {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var generation = 0

    var isVisible: Bool { panel != nil }

    func show(on notch: NotchScreen, duration: TimeInterval = 7.5) {
        dismiss(animated: false)
        generation += 1
        let currentGeneration = generation

        let width = min(440, notch.screen.frame.width - 32)
        let height: CGFloat = 70
        let screen = notch.screen.frame
        let x = min(
            max(notch.notchRect.midX - width / 2, screen.minX + 16),
            screen.maxX - width - 16
        )
        let top = notch.notchRect.minY - 8
        let y = max(screen.minY + 12, top - height)

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true

        let hosting = NSHostingView(rootView: GestureHintView())
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.dismiss()
        }
    }

    func dismiss(animated: Bool = true) {
        generation += 1
        hideTask?.cancel()
        hideTask = nil
        guard let panel else { return }
        self.panel = nil

        guard animated else {
            panel.orderOut(nil)
            panel.close()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
    }
}
