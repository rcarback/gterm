import XCTest
import UIKit
import GhosttyKit
@testable import gterm

/// Full-screen programs such as codex and grok turn on mouse reporting and
/// scroll their own view. A drag must reach them as wheel input instead of
/// opening Screen's history, which only holds a stale copy of their screen.
@MainActor
final class TouchScrollTests: XCTestCase {
    private static let ghostty = Ghostty.App()

    private func makeSurface() -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        surface.layoutIfNeeded()
        return surface
    }

    private func enableMouseReporting(_ surface: TerminalSurfaceView) async {
        // The modes codex and grok both send: button, drag, and any-motion
        // tracking with SGR encoding.
        surface.receive(Data("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h".utf8))
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            surface.isMouseCaptured
        }, object: nil)
        await fulfillment(of: [captured], timeout: 3)
    }

    private func drag(_ surface: TerminalSurfaceView, by distance: CGFloat) {
        let pan = ScrollPan()
        let action = NSSelectorFromString("handleScrollPan:")
        pan.current = .began
        surface.perform(action, with: pan)
        pan.current = .changed
        pan.translationY = distance
        surface.perform(action, with: pan)
    }

    func testDragReachesAMouseReportingProgramAsWheelInput() async throws {
        let surface = makeSurface()
        let recorder = OutputRecorder()
        surface.delegate = recorder
        await enableMouseReporting(surface)
        surface.onTouchScroll = { _ in false }

        drag(surface, by: surface.bounds.height / 4)

        // SGR wheel-up is button 64. Dragging down reveals older content,
        // which is what wheel-up asks the program for.
        let wheel = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            String(decoding: recorder.data, as: UTF8.self).contains("\u{1b}[<64;")
        }, object: nil)
        await fulfillment(of: [wheel], timeout: 3)
    }

    func testScreenHandsTheDragToAProgramThatReportsTheMouse() async {
        let surface = makeSurface()
        let attachment = ScreenAttachment()
        attachment.configure(surface)
        XCTAssertEqual(surface.onTouchScroll?(40), true, "A plain shell drag opens Screen history")

        await enableMouseReporting(surface)
        XCTAssertEqual(surface.onTouchScroll?(40), false, "The program scrolls its own view")
    }
}

private final class ScrollPan: UIPanGestureRecognizer {
    var current: UIGestureRecognizer.State = .possible
    var translationY: CGFloat = 0
    init() { super.init(target: nil, action: nil) }
    override var state: UIGestureRecognizer.State { get { current } set {} }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: 0, y: translationY) }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 40, y: 40) }
}

private final class OutputRecorder: TerminalSurfaceViewDelegate {
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.withLock { bytes } }
    func terminalSurface(_ view: TerminalSurfaceView, didProduceOutput data: Data) {
        lock.withLock { bytes.append(data) }
    }
    func terminalSurface(_ view: TerminalSurfaceView, didResizeToCols cols: Int, rows: Int) {}
}
