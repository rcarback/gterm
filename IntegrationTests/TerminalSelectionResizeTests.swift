import XCTest
import UIKit
import GhosttyKit
@testable import gterm

/// Taking a selection resigns the surface's first responder status, which
/// dismisses the keyboard and resizes the terminal underneath it. The
/// selection must survive that, and the grid must not reflow while the
/// selection's snapshot of it is still on screen.
@MainActor
final class TerminalSelectionResizeTests: XCTestCase {
    private static let ghostty = Ghostty.App()

    private func makeSurface() async throws -> (TerminalSurfaceView, ghostty_surface_t) {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        surface.layoutIfNeeded()
        let handle = try XCTUnwrap(surface.ghosttySurface)
        surface.receive(Data("hello world\r\n".utf8))
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            surface.readVisibleText().contains("hello world")
        }, object: nil)
        await fulfillment(of: [rendered], timeout: 3)
        return (surface, handle)
    }

    func testResizeWhileSelectingKeepsTheSelection() async throws {
        let (surface, handle) = try await makeSurface()
        let size = ghostty_surface_size(handle)
        let scale = UIScreen.main.scale
        surface.beginSelection(at: CGPoint(x: CGFloat(size.cell_width_px) / scale * 2.5,
                                           y: CGFloat(size.cell_height_px) / scale * 0.5))
        XCTAssertNotNil(surface.selectionView, "precondition: a word was selected")

        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 611)
        surface.layoutIfNeeded()

        XCTAssertNotNil(surface.selectionView, "a resize must not cancel an active selection")
    }

    func testGridStaysPinnedWhileSelectingAndSyncsAfterward() async throws {
        let (surface, handle) = try await makeSurface()
        let size = ghostty_surface_size(handle)
        let scale = UIScreen.main.scale
        surface.beginSelection(at: CGPoint(x: CGFloat(size.cell_width_px) / scale * 2.5,
                                           y: CGFloat(size.cell_height_px) / scale * 0.5))
        XCTAssertNotNil(surface.selectionView, "precondition: a word was selected")
        let pinned = ghostty_surface_size(handle).height_px

        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        surface.layoutIfNeeded()
        XCTAssertEqual(ghostty_surface_size(handle).height_px, pinned,
                       "the grid must not reflow under a selection that snapshotted it")

        surface.endSelection()
        surface.layoutIfNeeded()
        XCTAssertEqual(ghostty_surface_size(handle).height_px, UInt32(700 * scale),
                       "the deferred size must apply once the selection ends")
    }
}
