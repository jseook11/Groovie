import SwiftUI

struct NotchCapShape: Shape {
    var cornerRadius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(cornerRadius, rect.width / 2, rect.height)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}

struct VinylStageView: View {
    @ObservedObject var model: VinylViewModel
    let layout: VinylLayout

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = layout.recordCenter(in: size, exposure: model.exposure)

            ZStack(alignment: .topLeading) {
                // The record is rendered as a full circle. The hardware notch (or
                // the screen's top edge) hides its upper half. The housing stays
                // matte black while the disc keeps a separate glossy tone, so the
                // two materials read as nested objects rather than one silhouette.
                VinylDiscView(
                    radius: layout.recordRadius,
                    labelRadius: layout.labelRadius,
                    angle: model.angle,
                    title: model.trackTitle,
                    artist: model.trackArtist,
                    artwork: model.artwork,
                    skin: model.skin
                )
                .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 5)
                .position(center)

                hud(center: center)
                confirmGauge(size: size)

                if layout.hasNotchCap {
                    NotchCapShape()
                        .fill(VinylTheme.hardwareBlack)
                        .frame(width: layout.notchWidth, height: layout.capHeight)
                        .position(x: size.width / 2, y: layout.capHeight / 2)

                    // A short contact shadow keeps the glossy record from merging
                    // with the matte cap. It must stay subtle; the record is still
                    // meant to emerge from the housing.
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.32), location: 0),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: layout.notchWidth * 0.94, height: 9)
                    .blur(radius: 2)
                    .position(x: size.width / 2, y: layout.capHeight + 4.5)
                    .allowsHitTesting(false)

                    // The hardware edge: a hairline that fades at both ends.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.11), location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(0, layout.notchWidth - 30), height: 1)
                    .position(x: size.width / 2, y: layout.capHeight - 0.5)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    /// Semi-transparent "pull further to lock" meter shown below the record while
    /// it is out but has not been confirmed yet.
    @ViewBuilder
    private func confirmGauge(size: CGSize) -> some View {
        let progress = CGFloat(min(max(model.confirmProgress, 0), 1))
        let width: CGFloat = 128
        VStack(spacing: 4) {
            Text("더 당겨서 고정")
                .font(.system(size: 8, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.40))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(.white.opacity(0.58))
                    .frame(width: max(0, width * progress))
            }
            .frame(width: width, height: 3.5)
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(.black.opacity(0.22))
        )
        .opacity(model.showConfirmGauge ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: model.showConfirmGauge)
        .position(
            x: size.width / 2,
            y: layout.emergenceInset + layout.recordRadius + 34
        )
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hud(center: CGPoint) -> some View {
        if model.showTitle {
            VStack(spacing: 3) {
                Text(titleLine)
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.15)
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if model.showOffset {
                    Text(TimeOffsetFormatter.string(for: model.offsetSeconds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            .frame(width: layout.recordRadius * 1.55)
            .shadow(color: .black.opacity(0.72), radius: 2.5, x: 0, y: 1)
            .position(x: center.x, y: center.y + layout.recordRadius * 0.80)
            .animation(.easeOut(duration: 0.14), value: model.showOffset)
        }
    }

    private var titleLine: String {
        let title = model.trackTitle.isEmpty ? "Notch Vinyl" : model.trackTitle
        let artist = model.trackArtist
        return artist.isEmpty ? title : "\(title) · \(artist)"
    }
}

enum TimeOffsetFormatter {
    /// `−2.7s`, `+3.4s`, or `+1:03.4` for larger jumps.
    static func string(for seconds: Double) -> String {
        let magnitude = abs(seconds)
        if magnitude < 0.05 {
            return "0.0s"
        }
        let sign = seconds < 0 ? "−" : "+"
        if magnitude < 60 {
            return sign + String(format: "%.1fs", magnitude)
        }
        let minutes = Int(magnitude) / 60
        let remainder = magnitude - Double(minutes * 60)
        return sign + String(format: "%d:%04.1f", minutes, remainder)
    }
}
