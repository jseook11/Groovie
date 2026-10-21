import AppKit
import Combine

/// Everything the overlay renders. Mutated only on the main actor.
@MainActor
final class VinylViewModel: ObservableObject {
    @Published var phase: VinylPhase = .idle
    @Published var exposure: CGFloat = 0
    @Published var angle: Double = 0
    @Published var offsetSeconds: Double = 0
    @Published var confirmProgress: Double = 0
    @Published var showConfirmGauge = false

    @Published var trackTitle: String = ""
    @Published var trackArtist: String = ""
    @Published var isPlaying: Bool = false
    @Published var artwork: NSImage?
    @Published var canInteract: Bool = false
    @Published var availability: MusicAvailability = .appNotRunning
    @Published var permissionDenied: Bool = false
    @Published var isEnabled: Bool = true

    var showStage: Bool { phase.isEngaged }
    var showHoverCue: Bool { phase == .armed && isEnabled }
    var showOffset: Bool { phase == .scrubbing }
    var showTitle: Bool { phase.isHoldingRecord }
    var recordIsHeld: Bool { phase.isHoldingRecord }
}
