import XCTest

/// Stands in for UIApplication. Records every assertion taken and released so a
/// test can prove the app never leaks one, which iOS kills apps for.
private final class FakeBackgroundTaskHost: BackgroundTaskHost {
    var granted: [Int] = []
    var released: [Int] = []
    var refuse = false
    private var nextToken = 1
    private var expire: (() -> Void)?

    func beginTask(name: String, onExpire: @escaping () -> Void) -> Int? {
        if refuse { return nil }
        let token = nextToken
        nextToken += 1
        granted.append(token)
        expire = onExpire
        return token
    }

    func endTask(_ token: Int) {
        released.append(token)
    }

    /// Drive the expiration handler the way iOS does when the grant runs out.
    func fireExpiration() {
        let handler = expire
        expire = nil
        handler?()
    }
}

@MainActor
final class BackgroundTaskAssertionTests: XCTestCase {
    func testShortBackgroundPeriodReportsTheProcessKeptRunning() {
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        XCTAssertTrue(assertion.isHeld)
        XCTAssertEqual(assertion.end(), .heldThroughout)
        XCTAssertEqual(host.granted, [1])
        XCTAssertEqual(host.released, [1])
        XCTAssertFalse(assertion.isHeld)
    }

    func testExpiredAssertionReportsAnInterruption() {
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        host.fireExpiration()
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(assertion.end(), .interrupted)
    }

    func testExpirationReleasesTheAssertionExactlyOnce() {
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        host.fireExpiration()
        assertion.end()
        XCTAssertEqual(host.released, [1])
    }

    func testBeginningTwiceTakesOnlyOneAssertion() {
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        assertion.begin()
        XCTAssertEqual(host.granted, [1])
        XCTAssertEqual(assertion.end(), .heldThroughout)
        XCTAssertEqual(host.released, [1])
    }

    func testEndingTwiceReleasesOnlyOnce() {
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        assertion.end()
        assertion.end()
        XCTAssertEqual(host.released, [1])
    }

    func testRefusedAssertionReportsAnInterruption() {
        let host = FakeBackgroundTaskHost()
        host.refuse = true
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(assertion.end(), .interrupted)
        XCTAssertEqual(host.released, [])
    }

    func testEndingWithoutBeginningReportsNoInterruption() {
        // Control Center moves the app to .inactive and back to .active with no
        // .background phase. That must not cost a health check.
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        XCTAssertEqual(assertion.end(), .heldThroughout)
        XCTAssertEqual(host.granted, [])
        XCTAssertEqual(host.released, [])
    }

    func testANewBackgroundPeriodStartsCleanAfterAnExpiry() {
        let host = FakeBackgroundTaskHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        host.fireExpiration()
        XCTAssertEqual(assertion.end(), .interrupted)

        assertion.begin()
        XCTAssertEqual(assertion.end(), .heldThroughout)
        XCTAssertEqual(host.granted, [1, 2])
        XCTAssertEqual(host.released, [1, 2])
    }

    func testAssertionUsesTheNamedVariantForTraceability() {
        final class NameCapturingHost: BackgroundTaskHost {
            var name: String?
            func beginTask(name: String, onExpire: @escaping () -> Void) -> Int? {
                self.name = name
                return 1
            }
            func endTask(_ token: Int) {}
        }
        let host = NameCapturingHost()
        let assertion = BackgroundTaskAssertion(host: host)
        assertion.begin()
        XCTAssertEqual(host.name, "gterm.ssh-session")
    }
}
