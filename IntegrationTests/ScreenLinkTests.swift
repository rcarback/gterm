import XCTest
import UIKit
import GhosttyKit
@testable import gterm

/// Screen mode consumes taps to leave copy mode, and a program with mouse
/// reporting on stops libghostty tracking links at all. Links are resolved from
/// the grid text ahead of both, so neither can suppress them.
@MainActor
final class ScreenLinkTests: XCTestCase {
    private static let ghostty = Ghostty.App()

    private func makeSurface() throws -> (TerminalSurfaceView, ghostty_surface_size_s) {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        surface.layoutIfNeeded()
        let handle = try XCTUnwrap(surface.ghosttySurface)
        return (surface, ghostty_surface_size(handle))
    }

    private func tap(column: Double, row: Double, in size: ghostty_surface_size_s) -> LinkTap {
        let scale = UIScreen.main.scale
        return LinkTap(point: CGPoint(
            x: CGFloat(size.cell_width_px) / scale * column,
            y: CGFloat(size.cell_height_px) / scale * row
        ))
    }

    /// The case that stayed broken: scrolled back in Screen history, where
    /// `onTap` returns true to drop out of copy mode and previously swallowed
    /// the tap before any link handling ran.
    func testLinkOpensEvenWhenTheTapWouldOtherwiseBeConsumed() async throws {
        let (surface, size) = try makeSurface()
        let url = "https://example.com/copy-mode"
        surface.receive(Data((url + "\r\n").utf8))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            surface.readVisibleText().contains(url)
        }, object: nil)
        await fulfillment(of: [rendered], timeout: 3)

        var consumed = 0
        surface.onTap = { consumed += 1; return true }
        let opened = expectation(description: "Open the link despite the consumed tap")
        surface.onOpenURL = { actual in
            XCTAssertEqual(actual.absoluteString, url)
            opened.fulfill()
        }
        surface.perform(NSSelectorFromString("handleLinkTap:"), with: tap(column: 3.5, row: 0.5, in: size))
        await fulfillment(of: [opened], timeout: 3)
        XCTAssertEqual(consumed, 0, "The link must resolve before onTap can swallow the tap")
    }

    /// A tap that is not on a link must still reach the existing behavior.
    func testTapOffALinkStillFallsThroughToTheTapHandler() async throws {
        let (surface, size) = try makeSurface()
        surface.receive(Data("plain text only\r\n".utf8))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            surface.readVisibleText().contains("plain text only")
        }, object: nil)
        await fulfillment(of: [rendered], timeout: 3)

        var consumed = 0
        surface.onTap = { consumed += 1; return true }
        surface.onOpenURL = { _ in XCTFail("No link is under this tap") }
        surface.perform(NSSelectorFromString("handleLinkTap:"), with: tap(column: 2.5, row: 0.5, in: size))
        XCTAssertEqual(consumed, 1)
    }
}

private final class LinkTap: UITapGestureRecognizer {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
    override func location(in view: UIView?) -> CGPoint { point }
}
