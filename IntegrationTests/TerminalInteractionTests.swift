import XCTest
import UIKit
import SwiftUI
import GhosttyKit
@testable import gterm

@MainActor
final class TerminalInteractionTests: XCTestCase {
    private static let ghostty = Ghostty.App()

    func testSSHStopCanBeAwaitedRepeatedly() async {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        let ssh = SSHSession(connection: SSHConnection(host: "127.0.0.1", username: "test"),
                             view: surface, onStateChange: { _ in })
        ssh.stop()
        async let first: Void = ssh.stopAndWait()
        async let second: Void = ssh.stopAndWait()
        _ = await (first, second)
        await ssh.stopAndWait()
        do {
            try await ssh.checkConnection()
            XCTFail("Stopped SSH connection must fail the health check")
        } catch { XCTAssertEqual(error.localizedDescription, SSHExecError.notConnected.localizedDescription) }
    }

    func testTypingScrollsOnlyEnoughToKeepCursorAboveKeyboard() async throws {
        try await verifyTypingViewport(controlsVisible: true)
    }

    func testTypingKeepsFullBufferWithScreenControlsHidden() async throws {
        try await verifyTypingViewport(controlsVisible: false)
    }

    private func verifyTypingViewport(controlsVisible: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.keyWindow
        previousWindow?.endEditing(true)
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.followsCursorWhileTyping = true
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: NavigationStack {
                VStack(spacing: 0) {
                    TerminalView(surface: surface)
                    if controlsVisible {
                        Text("Screen controls").frame(height: 44)
                        Text("Screen window tabs").frame(height: 40)
                    }
                }
                .ignoresSafeArea(.keyboard)
                .navigationTitle("GNU Screen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
            })
        window.makeKeyAndVisible()
        surface.showKeyboardIfNeeded()
        defer {
            surface.collapseKeyboard()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        let keyboard = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in surface.isKeyboardPresented }, object: nil)
        await fulfillment(of: [keyboard], timeout: 5)
        let hidden = XCTNSNotificationExpectation(name: UIResponder.keyboardDidHideNotification)
        surface.collapseKeyboard()
        await fulfillment(of: [hidden], timeout: 5)
        window.layoutIfNeeded()
        let originalRows = surface.gridSize.rows
        let originalSize = surface.bounds.size
        let cursorRow = max(3, originalRows - 3)
        surface.receive(Data("\u{1b}[2J\u{1b}[\(cursorRow - 1);1HEarlier output\u{1b}[\(cursorRow);1HInput here\u{1b}[\(cursorRow + 1);1HNext row\u{1b}[\(cursorRow);11H".utf8))
        surface.showKeyboardIfNeeded()
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in surface.isKeyboardPresented }, object: nil)
        await fulfillment(of: [shown], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        let viewport = try XCTUnwrap(surface.superview)
        var x = 0.0, bottom = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(try XCTUnwrap(surface.ghosttySurface), &x, &bottom, &width, &height)
        let visibleBottom = surface.convert(CGPoint(x: 0, y: bottom + height), to: viewport).y
        XCTAssertEqual(visibleBottom, viewport.bounds.maxY, accuracy: 1)
        XCTAssertNil(surface.layer.mask)
        XCTAssertLessThan(surface.transform.ty, 0)
        XCTAssertGreaterThanOrEqual(surface.convert(CGPoint(x: 0, y: bottom - height * 2), to: viewport).y, 0)
        XCTAssertNil(viewport.hitTest(CGPoint(x: 10, y: viewport.bounds.maxY + 1), with: nil))
        XCTAssertEqual(surface.bounds.size, originalSize)
        XCTAssertEqual(surface.gridSize.rows, originalRows)
        surface.receive(Data("\u{1b}[\(originalRows);1H".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        ghostty_surface_ime_point(try XCTUnwrap(surface.ghosttySurface), &x, &bottom, &width, &height)
        XCTAssertEqual(surface.convert(CGPoint(x: 0, y: bottom + height), to: viewport).y,
                       viewport.bounds.maxY, accuracy: 1, "Keep one row of clearance even at the buffer bottom")
        surface.receive(Data("\u{1b}[3;1H".utf8))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(surface.transform, .identity, "Do not scroll when the cursor is already above the keyboard")
        XCTAssertEqual(surface.gridSize.rows, originalRows)
        surface.collapseKeyboard()
        XCTAssertEqual(surface.transform, .identity)
    }

    func testIMEBackspaceUsesAndClearsAltModifier() async {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        let recorder = KeyboardOutputRecorder()
        surface.delegate = recorder
        _ = surface.toggleAlt()
        surface.deleteBackward()
        surface.deleteBackward()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.data, Data([27, 127, 127]))
        XCTAssertTrue(surface.stickyMods.isEmpty)
    }

    func testLeavingScreenHistoryKeepsControlsHidden() {
        let attachment = ScreenAttachment()
        attachment.hideControls()
        attachment.returnToLive()
        XCTAssertTrue(attachment.controlsHidden)
        attachment.showControls()
        XCTAssertFalse(attachment.controlsHidden)
    }

    func testIMEDeleteMovesContextAndCanContinuePastItsInitialLength() async {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        var deletes = 0
        surface.onBeforeInput = { deletes += 1 }
        let start = surface.offset(from: surface.beginningOfDocument, to: surface.endOfDocument)
        surface.deleteBackward()
        XCTAssertLessThan(surface.offset(from: surface.beginningOfDocument, to: surface.endOfDocument), start)
        for _ in 0..<(start * 2) {
            surface.deleteBackward()
            await Task.yield()
        }
        XCTAssertEqual(deletes, 1 + start * 2)
        XCTAssertTrue(surface.hasText)
        XCTAssertGreaterThan(surface.offset(from: surface.beginningOfDocument, to: surface.endOfDocument), 0)
    }

    func testIMECompositionEditsLocallyAndCommitsOnce() throws {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        var inputs = 0
        surface.onBeforeInput = { inputs += 1 }
        surface.setMarkedText("に😀", selectedRange: NSRange(location: 3, length: 0))
        surface.deleteBackward()
        XCTAssertEqual(surface.text(in: try XCTUnwrap(surface.markedTextRange)), "に")
        XCTAssertEqual(inputs, 0)
        let start = surface.beginningOfDocument
        surface.selectedTextRange = surface.textRange(from: start, to: start)
        surface.deleteBackward()
        XCTAssertNil(surface.markedTextRange)
        XCTAssertEqual(inputs, 0)
        surface.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        surface.insertText("日本")
        XCTAssertEqual(inputs, 1)
        XCTAssertNil(surface.markedTextRange)
        surface.unmarkText()
        XCTAssertEqual(inputs, 1, "Unmark after commit must not send the text again")
        surface.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0))
        surface.deleteBackward()
        surface.deleteBackward()
        XCTAssertEqual(inputs, 2, "Deleting an empty composition must resume remote Backspace")
    }

    func testConsumedTapDoesNotShowKeyboardOrMoveCursor() {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        var taps = 0
        var inputs = 0
        surface.onTap = { taps += 1; return true }
        surface.onBeforeInput = { inputs += 1 }
        let tap = EndedTap()
        surface.perform(NSSelectorFromString("handleLinkTap:"), with: tap)
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(inputs, 0)
        XCTAssertFalse(surface.isFirstResponder)
    }

    func testStationaryHoldSelectsWithoutPasting() throws {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(surface)
        window.isHidden = false
        defer { window.isHidden = true }
        _ = try XCTUnwrap(surface.ghosttySurface)
        surface.receive(Data("hello world\r\n".utf8))
        var inputs = 0
        surface.onBeforeInput = { inputs += 1 }
        let hold = TestHold()
        surface.perform(NSSelectorFromString("handleSelectionLongPress:"), with: hold)
        let selection = try XCTUnwrap(surface.selectionView)
        XCTAssertFalse(selection.isEditable)
        XCTAssertTrue(selection.isSelectable)
        hold.phase = .ended
        surface.perform(NSSelectorFromString("handleSelectionLongPress:"), with: hold)
        XCTAssertEqual(inputs, 0)
        XCTAssertEqual(surface.scrollPan?.isEnabled, false)
        XCTAssertEqual(selection.text(in: try XCTUnwrap(selection.selectedTextRange)), "hello")
        selection.selectedRange = NSRange(location: 0, length: 11)
        XCTAssertEqual(selection.text(in: try XCTUnwrap(selection.selectedTextRange)), "hello world")
        selection.selectedRange = NSRange(location: 1, length: 3)
        XCTAssertEqual(selection.text(in: try XCTUnwrap(selection.selectedTextRange)), "ell")
        XCTAssertEqual(selection.selectedTerminalText(), "ell")
        surface.endSelection()
        XCTAssertEqual(surface.scrollPan?.isEnabled, true)
    }

    func testGeometryCallbackRunsOnlyWhenSizeChanges() {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.layoutSubviews()
        var changes = 0
        surface.onGeometryChange = { changes += 1 }
        surface.frame.size = CGSize(width: 600, height: 140)
        surface.layoutSubviews()
        surface.layoutSubviews()
        XCTAssertEqual(changes, 1)
        XCTAssertGreaterThan(surface.gridSize.rows, 0)
    }

    func testCopyPreservesSoftWrapsAndHardLineBreaks() async throws {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        surface.layoutSubviews()
        try await Task.sleep(nanoseconds: 100_000_000)
        let columns = surface.gridSize.cols
        let first = String(repeating: "a", count: columns)
        surface.receive(Data((first + "word\r\nnext").utf8))
        surface.beginSelection(at: CGPoint(x: 12, y: 8))
        let selection = try XCTUnwrap(surface.selectionView)
        XCTAssertTrue(selection.text.hasPrefix(first + "\nword\nnext"))
        selection.selectedRange = NSRange(location: 0, length: columns + 1 + 4)
        XCTAssertEqual(selection.selectedTerminalText(), first + "word")
        selection.selectedRange = NSRange(location: 0, length: columns + 1 + 4 + 1 + 4)
        XCTAssertEqual(selection.selectedTerminalText(), first + "word\nnext")
        surface.endSelection()
    }

    func testHoldingEmptySpaceDoesNotBlockScrolling() {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.beginSelection(at: CGPoint(x: 12, y: 8))
        XCTAssertNil(surface.selectionView)
        XCTAssertEqual(surface.scrollPan?.isEnabled, true)
    }

    func testSelectionSurvivesUnrelatedOutputButEndsWhenSelectedRowChanges() async throws {
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        surface.receive(Data("hello\r\nstatus".utf8))
        surface.beginSelection(at: CGPoint(x: 12, y: 8))
        XCTAssertNotNil(surface.selectionView)
        surface.receive(Data("\u{1b}[2;1HSTATUS".utf8))
        let unrelated = expectation(description: "Unrelated output processed")
        DispatchQueue.main.async { unrelated.fulfill() }
        await fulfillment(of: [unrelated], timeout: 2)
        XCTAssertNotNil(surface.selectionView)
        surface.receive(Data("\u{1b}[1;1HHELLO".utf8))
        let changed = expectation(description: "Selected row update processed")
        DispatchQueue.main.async { changed.fulfill() }
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertNil(surface.selectionView)
        XCTAssertEqual(surface.scrollPan?.isEnabled, true)
    }

    func testTerminalStaysAboveKeyboardEvenWithoutSwiftUIAvoidance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.keyWindow
        previousWindow?.endEditing(true)
        let surface = TerminalSurfaceView(ghostty: Self.ghostty)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: TerminalView(surface: surface).ignoresSafeArea(.keyboard)
        )
        let shown = XCTNSNotificationExpectation(name: UIResponder.keyboardDidShowNotification)
        window.makeKeyAndVisible()
        surface.showKeyboardIfNeeded()
        defer {
            surface.collapseKeyboard()
            window.isHidden = true
            previousWindow?.makeKey()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        await fulfillment(of: [shown], timeout: 5)
        XCTAssertTrue(surface.isKeyboardPresented)
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                scene.interfaceOrientation.isLandscape && surface.bounds.width > surface.bounds.height
            }, object: nil
        )
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
            XCTFail("Could not rotate test window: \(error)")
        }
        await fulfillment(of: [landscape], timeout: 5)
        window.layoutIfNeeded()
        let container = try XCTUnwrap(surface.superview?.superview)
        let keyboardTop = container.keyboardLayoutGuide.layoutFrame.minY
        XCTAssertGreaterThan(surface.bounds.height, 0)
        XCTAssertLessThan(surface.bounds.height, container.bounds.height)
        XCTAssertEqual(surface.convert(surface.bounds, to: container).maxY, keyboardTop, accuracy: 1)
        surface.perform(NSSelectorFromString("keyboardWillHide"))
        XCTAssertTrue(surface.isFirstResponder)
        XCTAssertFalse(surface.isKeyboardPresented)
    }
}

private final class EndedTap: UITapGestureRecognizer {
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
}

private final class TestHold: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .began
    override var state: UIGestureRecognizer.State { get { phase } set {} }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 12, y: 8) }
}

private final class KeyboardOutputRecorder: TerminalSurfaceViewDelegate {
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.withLock { bytes } }
    func terminalSurface(_ view: TerminalSurfaceView, didProduceOutput data: Data) {
        lock.withLock { bytes.append(data) }
    }
    func terminalSurface(_ view: TerminalSurfaceView, didResizeToCols cols: Int, rows: Int) {}
}
