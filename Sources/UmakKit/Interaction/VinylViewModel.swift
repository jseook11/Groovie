import AppKit
import Combine

/// Everything the overlay renders. Mutated only on the main actor.
@MainActor
final class VinylViewModel: ObservableObject {
    @Published var phase: VinylPhase = .idle
    @Published var exposure: CGFloat = 0
    @Published var angle: Double = 0
    /// Playback rotation, including its run-up and brake. Core Animation renders
    /// it from the same curve, so the angle is only sampled at transitions.
    @Published var spin: SpinMotion = .stopped
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
    @Published var skinID: String = VinylSkin.launchID

    var skin: VinylSkin { VinylSkin.skin(id: skinID) }

    var showStage: Bool { phase.isEngaged }
    var showHoverCue: Bool { phase == .armed && isEnabled }
    var showOffset: Bool { phase == .scrubbing }
    var showTitle: Bool { phase.isHoldingRecord }
    var recordIsHeld: Bool { phase.isHoldingRecord }
}

/// Hover feedback while the record is pinned. Kept separate from the main
/// view model so pointer movement invalidates only the small label overlay,
/// not the disc and the rest of the stage.
@MainActor
final class RecordHoverModel: ObservableObject {
    @Published var region: RecordHover = .none
}
