import AppKit
import SwiftUI

struct VinylDiscView: View {
    let radius: CGFloat
    let labelRadius: CGFloat
    let angle: Double
    let title: String
    let artist: String
    let artwork: NSImage?

    @State private var texture: NSImage?

    private var size: CGFloat { radius * 2 }

    private var textureKey: String {
        let artKey = artwork.map { String(ObjectIdentifier($0).hashValue) } ?? "-"
        return "\(title)|\(artist)|\(artKey)"
    }

    var body: some View {
        ZStack {
            Group {
                if let texture {
                    Image(nsImage: texture)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(angle))
                } else {
                    Circle()
                        .fill(VinylTheme.recordBase)
                        .frame(width: size, height: size)
                }
            }

            Circle()
                .fill(sheen)
                .blendMode(.screen)
                .frame(width: size, height: size)
                .allowsHitTesting(false)

            Circle()
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.75)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .onAppear(perform: rebuildTexture)
        .onChange(of: textureKey) { _, _ in rebuildTexture() }
    }

    private var sheen: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .white.opacity(0.050), location: 0.00),
                .init(color: .clear, location: 0.10),
                .init(color: .white.opacity(0.016), location: 0.32),
                .init(color: .clear, location: 0.47),
                .init(color: .white.opacity(0.034), location: 0.64),
                .init(color: .clear, location: 0.78),
                .init(color: .white.opacity(0.050), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(-24)
        )
    }

    private func rebuildTexture() {
        texture = RecordTexture.make(
            radius: radius,
            labelRadius: labelRadius,
            artwork: artwork,
            title: title,
            artist: artist
        )
    }
}
