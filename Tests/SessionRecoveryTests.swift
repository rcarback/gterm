import XCTest

@MainActor
final class SessionRecoveryTests: XCTestCase {
    func testHealthyConnectionSurvivesForegroundCheck() async {
        var probes = 0
        var reconnects = 0
        let recovery = SessionRecovery(check: { probes += 1 }, reconnect: { reconnects += 1 })
        await recovery.resume()
        XCTAssertEqual(probes, 0)
        recovery.enteredBackground()
        await recovery.resume()
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(reconnects, 0)
        XCTAssertFalse(recovery.isPending)
    }

    func testConcurrentResumeReconnectsOnlyOnce() async {
        var probes = 0
        var reconnects = 0
        var pending: CheckedContinuation<Void, Error>?
        let recovery = SessionRecovery(check: {
            probes += 1
            try await withCheckedThrowingContinuation { pending = $0 }
        }, reconnect: { reconnects += 1 })
        recovery.enteredBackground()
        let first = Task { await recovery.resume() }
        while pending == nil { await Task.yield() }
        let second = Task { await recovery.resume() }
        await Task.yield()
        pending?.resume(throwing: TestFailure.disconnected)
        await first.value
        await second.value
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(reconnects, 1)
    }

    func testExplicitCancellationCannotReconnectLater() async {
        var pending: CheckedContinuation<Void, Error>?
        var reconnects = 0
        let recovery = SessionRecovery(check: {
            try await withCheckedThrowingContinuation { pending = $0 }
        }, reconnect: { reconnects += 1 })
        recovery.enteredBackground()
        let resumed = Task { await recovery.resume() }
        while pending == nil { await Task.yield() }
        recovery.cancel()
        pending?.resume(throwing: TestFailure.disconnected)
        await resumed.value
        XCTAssertEqual(reconnects, 0)
        XCTAssertFalse(recovery.isPending)
    }

    private enum TestFailure: Error { case disconnected }
}
