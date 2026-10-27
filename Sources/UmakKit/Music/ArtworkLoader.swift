import AppKit
import Foundation

/// Downloads a Spotify cover and turns it into the same 320 px thumbnail the
/// embedded-artwork path produces. Network failures are reported as transient
/// so the service can retry; a missing or undecodable cover is permanent.
enum ArtworkLoader {
    enum Outcome {
        case image(NSImage)
        case permanentMiss
        case transientFailure
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    private static let decodeQueue = DispatchQueue(
        label: "com.umak.artwork.download",
        qos: .userInitiated
    )

    static func load(url: URL, maxPixelSize: Int, completion: @escaping (Outcome) -> Void) {
        let task = session.dataTask(with: url) { data, response, error in
            if error != nil {
                finish(.transientFailure, completion)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.transientFailure, completion)
                return
            }
            switch http.statusCode {
            case 200..<300:
                break
            case 404, 410:
                finish(.permanentMiss, completion)
                return
            case 403:
                // A CDN/WAF hiccup or a stale signed URL can heal; a later
                // read supplies a fresh URL for the same track.
                finish(.transientFailure, completion)
                return
            default:
                finish(.transientFailure, completion)
                return
            }
            if let mime = http.mimeType, !mime.hasPrefix("image/") {
                finish(.permanentMiss, completion)
                return
            }
            guard let data,
                  !data.isEmpty,
                  data.count <= ArtworkThumbnailer.maxArtworkBytes
            else {
                finish(.permanentMiss, completion)
                return
            }

            decodeQueue.async {
                if let image = ArtworkThumbnailer.thumbnail(from: data, maxPixelSize: maxPixelSize) {
                    finish(.image(image), completion)
                } else {
                    finish(.permanentMiss, completion)
                }
            }
        }
        task.resume()
    }

    private static func finish(_ outcome: Outcome, _ completion: @escaping (Outcome) -> Void) {
        DispatchQueue.main.async { completion(outcome) }
    }
}
