import Foundation

/// Counts outstanding keepalive round-trips for one SSH connection and decides
/// when silence means the connection is gone.
///
/// A peer answers `keepalive@openssh.com` with a refusal, because no server
/// implements that request name. The refusal is still a complete round-trip, so
/// callers record it with `recordReply()`. Only a total absence of any answer
/// counts as a miss.
struct KeepaliveTracker {
    /// Seconds between keepalives. Short enough to stay under a typical
    /// 60-second `ClientAliveInterval` and under common address-translation
    /// idle timeouts.
    static let defaultInterval: TimeInterval = 45

    /// Unanswered keepalives the connection may carry before it counts as dead.
    static let defaultMissLimit = 3

    let missLimit: Int
    private(set) var outstanding = 0

    init(missLimit: Int = KeepaliveTracker.defaultMissLimit) {
        self.missLimit = missLimit
    }

    mutating func recordSent() {
        outstanding += 1
    }

    /// Any answer, including a refusal, clears the whole backlog: one reply
    /// proves the connection round-trips right now.
    mutating func recordReply() {
        outstanding = 0
    }

    var isConnectionDead: Bool {
        outstanding > missLimit
    }
}
