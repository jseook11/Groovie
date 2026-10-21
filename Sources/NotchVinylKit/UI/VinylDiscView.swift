import AppKit
import SwiftUI

struct VinylDiscView: View {
    let radius: CGFloat
    let labelRadius: CGFloat
    let angle: Double
    let title: String
    let artist: String
    let artwork: NSImage?
    let skin: VinylSkin

    @State private var texture: NSImage?

    private var size: CGFloat { radius * 2 }

    private var textureKey: String {
        let artKey = artwork.map { String(ObjectIdentifier($0).hashValue) } ?? "-"
        return "\(skin.id)|\(title)|\(artist)|\(artKey)"
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
                        .fill(Color(nsColor: skin.recordCenter))
                        .frame(width: size, height: size)
                }
            }

            // A dark bevel just inside the rim, then light that stays fixed while
            // the disc rotates. This is what separates the glossy vinyl from the
            // matte notch.
            Circle()
                .strokeBorder(Color.black.opacity(0.30), lineWidth: 1.3)
                .frame(width: size - 2.6, height: size - 2.6)
                .allowsHitTesting(false)

            Circle()
                .fill(sheen)
                .blendMode(.screen)
                .frame(width: size, height: size)
                .allowsHitTesting(false)

            Circle()
                .fill(specular)
                .blendMode(.screen)
                .frame(width: size, height: size)
                .allowsHitTesting(false)

            Circle()
                .fill(hotspot)
                .blendMode(.screen)
                .frame(width: size, height: size)
                .allowsHitTesting(false)

            Circle()
                .strokeBorder(rim, lineWidth: 0.9)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .onAppear(perform: rebuildTexture)
        .onChange(of: textureKey) { _, _ in rebuildTexture() }
    }

    private var sheen: AngularGradient {
        let strength = Double(skin.sheenStrength)
        let color = Color(nsColor: skin.sheen)
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: color.opacity(0.17 * strength), location: 0.00),
                .init(color: .clear, location: 0.09),
                .init(color: color.opacity(0.055 * strength), location: 0.31),
                .init(color: .clear, location: 0.46),
                .init(color: color.opacity(0.10 * strength), location: 0.63),
                .init(color: .clear, location: 0.79),
                .init(color: color.opacity(0.17 * strength), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(-24)
        )
    }

    private var specular: LinearGradient {
        let strength = Double(skin.sheenStrength)
        let color = Color(nsColor: skin.sheen)
        return LinearGradient(
            stops: [
                .init(color: color.opacity(0.0), location: 0.0),
                .init(color: color.opacity(0.105 * strength), location: 0.20),
                .init(color: color.opacity(0.035 * strength), location: 0.46),
                .init(color: .clear, location: 0.72),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var hotspot: RadialGradient {
        let strength = Double(skin.sheenStrength)
        let color = Color(nsColor: skin.sheen)
        return RadialGradient(
            colors: [color.opacity(0.085 * strength), .clear],
            center: UnitPoint(x: 0.34, y: 0.26),
            startRadius: 0,
            endRadius: radius * 0.85
        )
    }

    private var rim: LinearGradient {
        let color = Color(nsColor: skin.sheen)
        return LinearGradient(
            colors: [color.opacity(0.34), color.opacity(0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func rebuildTexture() {
        texture = RecordTexture.make(
            radius: radius,
            labelRadius: labelRadius,
            artwork: artwork,
            title: title,
            artist: artist,
            skin: skin
        )
    }
}
