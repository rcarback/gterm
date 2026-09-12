import XCTest

final class BackgroundResumePolicyTests: XCTestCase {
    private let allStates: [SSHSessionState] = [
        .idle, .connecting, .authenticating, .connected, .failed("boom"), .closed
    ]

    // MARK: - isAlive

    func testOnlyFailedAndClosedAreNotAlive() {
        XCTAssertTrue(BackgroundResumePolicy.isAlive(.idle))
        XCTAssertTrue(BackgroundResumePolicy.isAlive(.connecting))
        XCTAssertTrue(BackgroundResumePolicy.isAlive(.authenticating))
        XCTAssertTrue(BackgroundResumePolicy.isAlive(.connected))
        XCTAssertFalse(BackgroundResumePolicy.isAlive(.failed("boom")))
        XCTAssertFalse(BackgroundResumePolicy.isAlive(.closed))
    }

    // MARK: - needsCheck

    func testInterruptionChecksEverySessionWhateverItsState() {
        for state in allStates {
            XCTAssertTrue(
                BackgroundResumePolicy.needsCheck(outcome: .interrupted, state: state),
                "a suspended process cannot trust \(state): it needs a round-trip"
            )
        }
    }

    func testHealthySessionHeldThroughoutNeedsNoCheck() {
        XCTAssertFalse(
            BackgroundResumePolicy.needsCheck(outcome: .heldThroughout, state: .connected)
        )
    }

    /// The defect this policy was extracted to prevent. A session that dies
    /// while the app is backgrounded must be checked on return even though the
    /// assertion covered the whole absence. Marking by assertion outcome alone
    /// let `TerminalScreen` dismiss the terminal and prune the session instead.
    func testSessionThatDiedDuringAHeldBackgroundIsStillChecked() {
        XCTAssertTrue(
            BackgroundResumePolicy.needsCheck(outcome: .heldThroughout, state: .closed)
        )
        XCTAssertTrue(
            BackgroundResumePolicy.needsCheck(outcome: .heldThroughout, state: .failed("boom"))
        )
    }

    func testHeldThroughoutChecksExactlyTheDeadStates() {
        for state in allStates {
            XCTAssertEqual(
                BackgroundResumePolicy.needsCheck(outcome: .heldThroughout, state: state),
                !BackgroundResumePolicy.isAlive(state),
                "with the assertion held, state alone decides for \(state)"
            )
        }
    }

    func testAConnectingSessionIsNotTornDownForBeingUnfinished() {
        XCTAssertFalse(
            BackgroundResumePolicy.needsCheck(outcome: .heldThroughout, state: .connecting)
        )
        XCTAssertFalse(
            BackgroundResumePolicy.needsCheck(outcome: .heldThroughout, state: .authenticating)
        )
    }
}
