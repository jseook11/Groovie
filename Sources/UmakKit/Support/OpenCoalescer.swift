import Foundation

/// Serialises "open the player app" requests.
///
/// A scroll gesture asks for the player once per event, and every request
/// would otherwise reach LaunchServices and then trigger a read on the shared
/// AppleScript queue when it completes. One request at a time is enough: the
/// app is either already opening or already in front, and a dropped duplicate
/// has nothing left to do.
///
/// Tokens instead of a plain `Bool` keep a late completion from a stopped or
/// restarted service from releasing the claim of the request that replaced it.
/// The claim also expires: a LaunchServices completion that never arrives must
/// not disable presenting the player for the rest of the session.
struct OpenCoalescer {
    /// Long enough for a cold app launch and its registration, short enough
    /// that a lost completion is not felt as a broken gesture.
    static let defaultTimeout: TimeInterval = 5

    let timeout: TimeInterval
    private var nextToken = 0
    private var inFlight: Int?
    private var deadline: Date?

    init(timeout: TimeInterval = OpenCoalescer.defaultTimeout) {
        self.timeout = timeout
    }

    /// Claims the right to start an open. Returns nil while one is pending and
    /// still within its timeout.
    mutating func begin(at now: Date = Date()) -> Int? {
        if let deadline, now < deadline { return nil }
        // An expired claim belongs to a completion that is not coming.
        self.deadline = nil
        inFlight = nil
        nextToken += 1
        inFlight = nextToken
        self.deadline = now.addingTimeInterval(timeout)
        return nextToken
    }

    /// Releases the claim held by `token`. Returns false when the completion
    /// belongs to a superseded or expired request, whose result must be ignored.
    mutating func finish(_ token: Int) -> Bool {
        guard inFlight == token else { return false }
        inFlight = nil
        deadline = nil
        return true
    }

    /// Drops the claim without a completion, so a stopped service does not keep
    /// the next start from opening its player.
    mutating func reset() {
        inFlight = nil
        deadline = nil
    }

    var isInFlight: Bool { inFlight != nil }
}
