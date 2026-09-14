import XCTest
import UIKit
@testable import gterm

/// Screen mode attaches to its own `TerminalSurfaceView`, built by
/// `ScreenAttachment` rather than by `ActiveSession`. Every surface callback is
/// per-instance, so a tapped link only reaches the in-app browser if this
/// surface is wired for it too.
@MainActor
final class ScreenLinkTests: XCTestCase {
    private static let ghostty = Ghostty.App()

    func testConfiguredSurfaceRoutesTappedLinkToBrowser() {
        let attachment = ScreenAttachment()
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        attachment.configure(surface)
        XCTAssertNil(attachment.linkURL)
        surface.didRequestOpenURL("https://example.com/docs")
        XCTAssertEqual(attachment.linkURL?.url.absoluteString, "https://example.com/docs")
    }

    /// A string libghostty hands over that is not a usable URL must leave the
    /// browser closed rather than presenting an empty cover.
    func testUnparsableURLDoesNotOpenBrowser() {
        let attachment = ScreenAttachment()
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        attachment.configure(surface)
        surface.didRequestOpenURL("")
        XCTAssertNil(attachment.linkURL)
    }
}
