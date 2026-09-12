import UIKit

/// Backs `BackgroundTaskAssertion` with the real `UIApplication`.
///
/// `UIBackgroundTaskIdentifier` wraps an `Int`, so the token crosses the
/// protocol as a plain `Int` and `BackgroundTaskAssertion` stays free of UIKit.
final class UIKitBackgroundTaskHost: BackgroundTaskHost {
    func beginTask(name: String, onExpire: @escaping () -> Void) -> Int? {
        // Apple documents that the expiration handler runs on the main thread.
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { onExpire() }
        }
        guard identifier != .invalid else { return nil }
        return identifier.rawValue
    }

    func endTask(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}
