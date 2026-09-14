import XCTest

/// The finder works from two strings the surface can always read, whatever the
/// remote program is doing: the whole viewport (soft-wrapped rows already
/// joined) and the single row under the tap.
final class TerminalLinkFinderTests: XCTestCase {
    func testFindsTheURLUnderTheTap() {
        let row = "see https://example.com/docs for details"
        XCTAssertEqual(
            TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 10)?.absoluteString,
            "https://example.com/docs"
        )
    }

    func testTapOutsideTheURLFindsNothing() {
        let row = "see https://example.com/docs for details"
        XCTAssertNil(TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 1))
    }

    /// A tap on the continuation of a wrapped URL must open the whole URL. The
    /// viewport read carries it joined; the tapped row holds only the tail.
    func testTapOnWrappedContinuationReturnsTheWholeURL() {
        let whole = "https://example.com/" + String(repeating: "a", count: 40)
        let tail = String(repeating: "a", count: 20)
        XCTAssertEqual(
            TerminalLinkFinder.url(visibleText: whole, rowText: tail, tapColumn: 5)?.absoluteString,
            whole
        )
    }

    func testPicksTheURLContainingTheTappedToken() {
        let row = "https://alpha.example/one https://beta.example/two"
        XCTAssertEqual(
            TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 30)?.absoluteString,
            "https://beta.example/two"
        )
    }

    func testTapOnWhitespaceFindsNothing() {
        let row = "see https://example.com/docs for details"
        XCTAssertNil(TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 3))
    }

    func testTapOnPlainTextFindsNothing() {
        let row = "no links on this line at all"
        XCTAssertNil(TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 5))
    }

    /// Sentence punctuation is common right after a URL and is not part of it.
    func testTrailingSentencePunctuationIsExcluded() {
        let row = "visit https://example.com/docs."
        XCTAssertEqual(
            TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 12)?.absoluteString,
            "https://example.com/docs"
        )
    }

    /// A URL wrapped in parentheses keeps its own balanced parens but not the
    /// surrounding ones.
    func testSurroundingParenthesesAreExcluded() {
        let row = "(https://example.com/a)"
        XCTAssertEqual(
            TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 5)?.absoluteString,
            "https://example.com/a"
        )
    }

    func testSchemelessTextIsNotTreatedAsALink() {
        let row = "example.com/docs"
        XCTAssertNil(TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 3))
    }

    func testColumnBeyondTheRowFindsNothing() {
        let row = "https://example.com"
        XCTAssertNil(TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 999))
        XCTAssertNil(TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: -1))
    }

    func testNonHTTPSchemesAreFound() {
        let row = "mail me at mailto:someone@example.com ok"
        XCTAssertEqual(
            TerminalLinkFinder.url(visibleText: row, rowText: row, tapColumn: 20)?.absoluteString,
            "mailto:someone@example.com"
        )
    }
}
