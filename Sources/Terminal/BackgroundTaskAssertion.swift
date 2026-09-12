import Foundation

/// The `UIApplication` surface a `BackgroundTaskAssertion` needs, narrowed to
/// two calls so the assertion can be tested without UIKit.
protocol BackgroundTaskHost: AnyObject {
    /// Ask the system to defer suspension. Returns an opaque token, or nil when
    /// the system refuses. `onExpire` runs on the main thread.
    func beginTask(name: String, onExpire: @escaping () -> Void) -> Int?

    /// Release an assertion taken by `beginTask`.
    func endTask(_ token: Int)
}

/// Holds at most one `beginBackgroundTask` assertion for the whole app, and
/// reports whether the process kept running for the entire background period.
///
/// iOS grants roughly 30 seconds of deferred suspension, and the grant is a
/// property of the app rather than of each assertion. Taking one per session
/// would add no time and would push the app toward the documented cap of about
/// 1000 assertions, so exactly one lives here.
///
/// Leaking an assertion gets an app killed, so `begin()` and `end()` are both
/// idempotent and expiry releases the token on the way out.
@MainActor
final class BackgroundTaskAssertion {
    enum Outcome: Equatable {
        /// The process ran for the whole period. Live sessions were never cut off.
        case heldThroughout
        /// The system expired or refused the assertion. Sessions need a health check.
        case interrupted
    }

    private let host: BackgroundTaskHost
    private let name: String
    private var token: Int?
    private var begun = false
    private var interrupted = false

    init(host: BackgroundTaskHost, name: String = "gterm.ssh-session") {
        self.host = host
        self.name = name
    }

    var isHeld: Bool { token != nil }

    /// Take the assertion. A second call while one is held does nothing.
    func begin() {
        guard !begun else { return }
        begun = true
        interrupted = false
        token = host.beginTask(name: name) { [weak self] in
            self?.handleExpiration()
        }
        // A refusal means the process may suspend at any moment.
        if token == nil { interrupted = true }
    }

    /// Release the assertion and report what happened while it was held.
    @discardableResult
    func end() -> Outcome {
        guard begun else { return .heldThroughout }
        if let token {
            host.endTask(token)
            self.token = nil
        }
        begun = false
        let outcome: Outcome = interrupted ? .interrupted : .heldThroughout
        interrupted = false
        return outcome
    }

    private func handleExpiration() {
        interrupted = true
        guard let token else { return }
        self.token = nil
        host.endTask(token)
    }
}
