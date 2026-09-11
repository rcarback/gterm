import XCTest
import UIKit
import GhosttyKit
@testable import gterm

@MainActor
final class TerminalLinkTests: XCTestCase {
    private static let ghostty = Ghostty.App()

    func testTapOnWrappedURLContinuationOpensWholeURL() async throws {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        surface.layoutIfNeeded()
        let handle = try XCTUnwrap(surface.ghosttySurface)
        let size = ghostty_surface_size(handle)
        let columns = Int(size.columns)
        XCTAssertGreaterThan(columns, 10)
        let url = "https://example.com/" + String(repeating: "a", count: columns * 2)
        surface.receive(Data((url + "\r\n").utf8))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            surface.readVisibleText().contains(url)
        }, object: nil)
        await fulfillment(of: [rendered], timeout: 3)
        let opened = expectation(description: "Open full wrapped URL")
        surface.onOpenURL = { actual in
            XCTAssertEqual(actual.absoluteString, url)
            opened.fulfill()
        }
        let scale = UIScreen.main.scale
        let tap = LinkTestTap(point: CGPoint(x: CGFloat(size.cell_width_px) / scale * 3.5,
                                            y: CGFloat(size.cell_height_px) / scale * 1.5))
        surface.perform(NSSelectorFromString("handleLinkTap:"), with: tap)
        await fulfillment(of: [opened], timeout: 3)
    }
}

private final class LinkTestTap: UITapGestureRecognizer {
    let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
    override func location(in view: UIView?) -> CGPoint { point }
}
