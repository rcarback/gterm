import XCTest

/// The finder works from the grid itself: one string per row, each the full
/// width, so a column index means the same thing on every row.
final class TerminalLinkFinderTests: XCTestCase {
    private func url(_ rows: [String], columns: Int, row: Int, column: Int) -> String? {
        TerminalLinkFinder.url(rows: rows, columns: columns, tapRow: row, tapColumn: column)?
            .absoluteString
    }

    func testFindsTheURLUnderTheTap() {
        let rows = ["see https://example.com/docs for details"]
        XCTAssertEqual(url(rows, columns: 80, row: 0, column: 10), "https://example.com/docs")
    }

    func testTapOutsideTheURLFindsNothing() {
        let rows = ["see https://example.com/docs for details"]
        XCTAssertNil(url(rows, columns: 80, row: 0, column: 1))
    }

    func testTapOnWhitespaceFindsNothing() {
        let rows = ["see https://example.com/docs for details"]
        XCTAssertNil(url(rows, columns: 80, row: 0, column: 3))
    }

    /// GNU Screen redraws with real line breaks rather than soft-wrapping, so a
    /// URL across rows is only recoverable by joining a row that reaches its
    /// last column. "https://example.com/" is exactly 20 characters.
    func testJoinsARowThatReachesTheLastColumn() {
        let rows = ["https://example.com/", "docs/page"]
        XCTAssertEqual(url(rows, columns: 20, row: 1, column: 2), "https://example.com/docs/page")
    }

    func testTappingTheFirstRowOfAWrappedURLAlsoOpensTheWhole() {
        let rows = ["https://example.com/", "docs/page"]
        XCTAssertEqual(url(rows, columns: 20, row: 0, column: 5), "https://example.com/docs/page")
    }

    func testJoinsAcrossThreeRows() {
        let rows = ["https://ex", "ample.com/", "docs"]
        XCTAssertEqual(url(rows, columns: 10, row: 2, column: 1), "https://example.com/docs")
    }

    /// A row that stops short of the last column ended on its own, so the next
    /// row is unrelated text and must not be pulled in.
    func testDoesNotJoinARowThatEndsEarly() {
        let rows = ["https://example.com", "docs"]
        XCTAssertNil(url(rows, columns: 30, row: 1, column: 1))
    }

    func testShortRowKeepsItsOwnURLIntact() {
        let rows = ["https://example.com", "docs"]
        XCTAssertEqual(url(rows, columns: 30, row: 0, column: 9), "https://example.com")
    }

    /// A full-width read pads with blanks; that padding must not count toward
    /// filling the row.
    func testTrailingBlankPaddingDoesNotCountAsFilled() {
        let rows = ["https://example.com" + String(repeating: " ", count: 11), "docs"]
        XCTAssertNil(url(rows, columns: 30, row: 1, column: 1))
    }

    func testPicksTheURLContainingTheTappedToken() {
        let rows = ["https://alpha.example/one https://beta.example/two"]
        XCTAssertEqual(url(rows, columns: 80, row: 0, column: 30), "https://beta.example/two")
    }

    func testTapOnPlainTextFindsNothing() {
        XCTAssertNil(url(["no links on this line at all"], columns: 80, row: 0, column: 5))
    }

    func testTrailingSentencePunctuationIsExcluded() {
        let rows = ["visit https://example.com/docs."]
        XCTAssertEqual(url(rows, columns: 80, row: 0, column: 12), "https://example.com/docs")
    }

    func testSurroundingParenthesesAreExcluded() {
        XCTAssertEqual(url(["(https://example.com/a)"], columns: 80, row: 0, column: 5),
                       "https://example.com/a")
    }

    func testSchemelessTextIsNotTreatedAsALink() {
        XCTAssertNil(url(["example.com/docs"], columns: 80, row: 0, column: 3))
    }

    func testOutOfRangeTapsFindNothing() {
        let rows = ["https://example.com"]
        XCTAssertNil(url(rows, columns: 80, row: 0, column: 999))
        XCTAssertNil(url(rows, columns: 80, row: 0, column: -1))
        XCTAssertNil(url(rows, columns: 80, row: 5, column: 1))
        XCTAssertNil(url([], columns: 80, row: 0, column: 0))
    }

    func testNonHTTPSchemesAreFound() {
        let rows = ["mail me at mailto:someone@example.com ok"]
        XCTAssertEqual(url(rows, columns: 80, row: 0, column: 20), "mailto:someone@example.com")
    }
}
