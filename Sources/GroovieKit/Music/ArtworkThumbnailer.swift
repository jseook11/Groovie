import AppKit
import ImageIO

/// ImageIO thumbnail path shared by embedded artwork (Music) and downloaded
/// covers (Spotify). Decoding and downsampling stay off the main thread; both
/// callers run this on their own queue.
enum ArtworkThumbnailer {
    /// Covers larger than this are treated as broken rather than materialised
    /// and decoded. Typical artwork is a few megabytes.
    static let maxArtworkBytes = 32 * 1024 * 1024
    /// Reject pathological dimensions before ImageIO can allocate for them.
    static let maxArtworkDimension = 20_000
    static let maxArtworkPixels = 100_000_000

    static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard data.count <= maxArtworkBytes else { return nil }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // The header is cheap to inspect and catches an image whose dimensions
        // are absurd even when the encoded file is small.
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0,
           height > 0,
           width > maxArtworkDimension
               || height > maxArtworkDimension
               || width * height > maxArtworkPixels {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Decode now while we are on the artwork queue instead of leaving a
            // lazy image for the main thread to decode later.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
