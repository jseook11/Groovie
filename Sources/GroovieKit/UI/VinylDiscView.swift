import AppKit
import SwiftUI

struct VinylDiscView: View {
    let radius: CGFloat
    let labelRadius: CGFloat
    let angle: Double
    let spin: DiscSpin
    let degreesPerSecond: Double
    let title: String
    let artist: String
    let artwork: NSImage?
    let skin: VinylSkin

    @State private var texture: NSImage?

    private var size: CGFloat { radius * 2 }

    private var textureKey: String {
        RecordTexture.textureKey(
            radius: radius,
            labelRadius: labelRadius,
            artwork: artwork,
            title: title,
            artist: artist,
            skin: skin
        )
    }

    var body: some View {
        ZStack {
            Group {
                if let texture {
                    RotatingDiscView(
                        image: texture,
                        size: size,
                        angle: angle,
                        spin: spin,
                        degreesPerSecond: degreesPerSecond
                    )
                    .frame(width: size, height: size)
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
        .task(id: textureKey) {
            await loadTexture()
        }
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

    @MainActor
    private func loadTexture() async {
        let key = textureKey
        if let cached = RecordTexture.cachedTexture(for: key) {
            texture = cached
            return
        }

        let image = await RecordTextureRenderer.make(
            radius: radius,
            labelRadius: labelRadius,
            artwork: artwork,
            title: title,
            artist: artist,
            skin: skin
        )

        // A cancelled task belongs to an older track or a view that has gone
        // away. The texture is already in the cache; do not publish it over
        // the one the current view is showing.
        guard !Task.isCancelled else { return }
        texture = image
    }
}

/// Records are rasterised off the main thread: a full texture used to take
/// around 10 ms, which is long enough to register as a CPU spike in the middle
/// of a SwiftUI update. The static vinyl base makes later renders much cheaper,
/// but keeping even that work off the main thread protects interaction.
enum RecordTextureRenderer {
    private static let queue = DispatchQueue(
        label: "com.groovie.record-texture",
        qos: .userInitiated
    )

    static func make(
        radius: CGFloat,
        labelRadius: CGFloat,
        artwork: NSImage?,
        title: String,
        artist: String,
        skin: VinylSkin
    ) async -> NSImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            queue.async {
                let image = RecordTexture.make(
                    radius: radius,
                    labelRadius: labelRadius,
                    artwork: artwork,
                    title: title,
                    artist: artist,
                    skin: skin
                )
                continuation.resume(returning: image)
            }
        }
    }
}
