import Foundation
import QuartzCore

/// TEMPORARY diagnostic sink. Remove once the spin hand-off is fixed.
enum Diag {
    private static let queue = DispatchQueue(label: "com.groovie.diag")
    private static let url = URL(fileURLWithPath: "/tmp/groovie-diag.log")

    static func log(_ message: String) {
        let stamp = String(format: "%.3f", CACurrentMediaTime())
        queue.async {
            let line = stamp + " " + message + "\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

extension DiscSpin {
    var diagName: String {
        switch self {
        case .stopped: return "stopped"
        case .spinningUp(let up): return "up(\(String(format: "%.2f", up.since)))"
        case .spinning(let ref): return "spin(\(String(format: "%.2f", ref.since)))"
        case .coasting(let down): return "coast(\(String(format: "%.2f", down.since)))"
        }
    }
}
