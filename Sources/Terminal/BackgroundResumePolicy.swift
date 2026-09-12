import Foundation

/// Decides which sessions need a health check when the app returns to the
/// foreground.
///
/// This is a pure decision kept out of `SessionManager` so it can be tested.
/// The cost sits on both sides of it: marking too eagerly rebuilds a healthy
/// transport after a ten-second glance at another app, and marking too late
/// lets a session that died during the background be dismissed instead of
/// reconnected.
enum BackgroundResumePolicy {
    /// Whether a session needs a liveness check now that the app is active.
    ///
    /// - Parameters:
    ///   - outcome: whether the background task assertion covered the whole
    ///     absence. An interruption means the process was suspended, so even a
    ///     session that still reads as connected needs a round-trip proof.
    ///   - state: the session's state at the moment the app returned.
    static func needsCheck(outcome: BackgroundTaskAssertion.Outcome,
                           state: SSHSessionState) -> Bool {
        outcome == .interrupted || !isAlive(state)
    }

    /// Whether a session is worth keeping on screen. `.failed` and `.closed`
    /// are the only terminal states: the rest are either working or on the way
    /// to working.
    static func isAlive(_ state: SSHSessionState) -> Bool {
        switch state {
        case .failed, .closed: return false
        case .idle, .connecting, .authenticating, .connected: return true
        }
    }
}
