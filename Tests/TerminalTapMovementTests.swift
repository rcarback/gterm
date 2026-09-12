import XCTest

final class TerminalTapMovementTests: XCTestCase {
    func testTapMapsToLeftAndRightCellsOnCursorRow() {
        XCTAssertEqual(steps(x: 25, y: 15), -3)
        XCTAssertEqual(steps(x: 85, y: 15), 3)
        XCTAssertEqual(steps(x: 59, y: 15), 0)
    }

    func testOtherRowsAndInvalidGeometryDoNotMoveCursor() {
        XCTAssertNil(steps(x: 25, y: 9))
        XCTAssertNil(steps(x: 25, y: 20))
        XCTAssertNil(steps(x: -1, y: 15))
        XCTAssertNil(steps(x: .infinity, y: 15))
        XCTAssertNil(TerminalTapMovement.horizontalSteps(tapX: 25, tapY: 15, cursorX: 55,
            cursorBottom: 20, cellWidth: 0, cellHeight: 10, columns: 80))
    }

    private func steps(x: Double, y: Double) -> Int? {
        TerminalTapMovement.horizontalSteps(tapX: x, tapY: y, cursorX: 55,
            cursorBottom: 20, cellWidth: 10, cellHeight: 10, columns: 80)
    }
}
