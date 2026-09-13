import XCTest

final class KeepaliveTrackerTests: XCTestCase {
    func testFreshTrackerIsAlive() {
        let tracker = KeepaliveTracker()
        XCTAssertEqual(tracker.outstanding, 0)
        XCTAssertFalse(tracker.isConnectionDead)
    }

    func testAnsweredKeepalivesNeverAccumulate() {
        var tracker = KeepaliveTracker(missLimit: 1)
        for _ in 0..<100 {
            tracker.recordSent()
            tracker.recordReply()
        }
        XCTAssertEqual(tracker.outstanding, 0)
        XCTAssertFalse(tracker.isConnectionDead)
    }

    func testConnectionSurvivesExactlyTheMissLimit() {
        var tracker = KeepaliveTracker(missLimit: 3)
        tracker.recordSent()
        tracker.recordSent()
        tracker.recordSent()
        XCTAssertEqual(tracker.outstanding, 3)
        XCTAssertFalse(tracker.isConnectionDead)
    }

    func testConnectionDiesOneSendPastTheMissLimit() {
        var tracker = KeepaliveTracker(missLimit: 3)
        for _ in 0..<4 { tracker.recordSent() }
        XCTAssertEqual(tracker.outstanding, 4)
        XCTAssertTrue(tracker.isConnectionDead)
    }

    func testOneLateReplyClearsTheWholeBacklog() {
        var tracker = KeepaliveTracker(missLimit: 3)
        for _ in 0..<3 { tracker.recordSent() }
        tracker.recordReply()
        XCTAssertEqual(tracker.outstanding, 0)
        XCTAssertFalse(tracker.isConnectionDead)
    }

    func testReplyWithNothingOutstandingDoesNotUnderflow() {
        var tracker = KeepaliveTracker()
        tracker.recordReply()
        tracker.recordReply()
        XCTAssertEqual(tracker.outstanding, 0)
        XCTAssertFalse(tracker.isConnectionDead)
    }

    func testMissLimitOfZeroDiesOnTheFirstUnansweredSend() {
        var tracker = KeepaliveTracker(missLimit: 0)
        tracker.recordSent()
        XCTAssertTrue(tracker.isConnectionDead)
    }

    func testDefaultsMatchTheSpec() {
        XCTAssertEqual(KeepaliveTracker.defaultInterval, 45)
        XCTAssertEqual(KeepaliveTracker.defaultMissLimit, 3)
    }
}
