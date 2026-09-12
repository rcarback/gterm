import Foundation
import XCTest

final class ScreenProtocolTests: XCTestCase {
    func testReachingBottomExitsCopyModeWithoutSendingMoreMovement() {
        var input = ScreenScrollInput()
        _ = input.scroll(points: 30, pointsPerLine: 10, historyLimit: 1000)
        _ = input.scroll(points: -20, pointsPerLine: 10, historyLimit: 1000)
        XCTAssertTrue(input.isActive)
        let final = input.scroll(points: -100, pointsPerLine: 10, historyLimit: 1000)
        XCTAssertEqual(final, Data((ScreenProtocol.scrollEntry + ScreenProtocol.scrollNewer + ScreenProtocol.scrollExit).utf8))
        XCTAssertFalse(input.isActive)
        XCTAssertTrue(input.scroll(points: -50, pointsPerLine: 10, historyLimit: 1000).isEmpty)
        XCTAssertTrue(input.returnToLive().isEmpty)
    }

    func testOverscrollingOldestHistoryDoesNotDelayReturnToLive() {
        var input = ScreenScrollInput()
        _ = input.scroll(points: 1000, pointsPerLine: 10, historyLimit: 3)
        XCTAssertTrue(input.scroll(points: 1000, pointsPerLine: 10, historyLimit: 3).isEmpty)
        let final = input.scroll(points: -30, pointsPerLine: 10, historyLimit: 3)
        XCTAssertTrue(final.suffix(ScreenProtocol.scrollExit.utf8.count).elementsEqual(ScreenProtocol.scrollExit.utf8))
        XCTAssertFalse(input.isActive)
        XCTAssertTrue(input.scroll(points: 30, pointsPerLine: 10, historyLimit: 0).isEmpty)
    }

    func testHistorySizeUsesGeometryRatherThanNumbersInTheTitle() throws {
        XCTAssertEqual(try ScreenProtocol.historyLimit("(11,24)/(80,24)+1024 +flow UTF-8 2(zsh 99)\ngterm-history-lines:1048"), 1024)
        XCTAssertEqual(try ScreenProtocol.historyLimit("(1,1)/(80,24)+0 +flow\ngterm-history-lines:24"), 0)
        XCTAssertEqual(try ScreenProtocol.historyLimit("(1,1)/(80,24)+1024 +flow\ngterm-history-lines:34"), 10)
        XCTAssertThrowsError(try ScreenProtocol.historyLimit("(1,1)/(80,24)+1024 +flow\ngterm-history-lines:3"))
        for value in ["", "permission denied", "(1,1)/(80,24)+-1", "(1,1)/(80,24)+3oops"] {
            XCTAssertThrowsError(try ScreenProtocol.historyLimit(value))
        }
    }

    func testEveryScrollUsesModeIndependentScreenBinding() {
        var input = ScreenScrollInput()
        XCTAssertEqual(input.scroll(points: 6, pointsPerLine: 10, historyLimit: 1000), Data())
        XCTAssertEqual(input.scroll(points: 14, pointsPerLine: 10, historyLimit: 1000), Data("\u{1}\u{1f}gterm-scroll;0~\u{1}\u{1f}gterm-scroll;1~\u{1}\u{1f}gterm-scroll;1~".utf8))
        XCTAssertTrue(input.isActive)
        XCTAssertEqual(input.scroll(points: 10, pointsPerLine: 10, historyLimit: 1000), Data("\u{1}\u{1f}gterm-scroll;0~\u{1}\u{1f}gterm-scroll;1~".utf8))
        XCTAssertEqual(input.scroll(points: -20, pointsPerLine: 10, historyLimit: 1000), Data("\u{1}\u{1f}gterm-scroll;0~\u{1}\u{1f}gterm-scroll;2~\u{1}\u{1f}gterm-scroll;2~".utf8))
        XCTAssertEqual(input.returnToLive(), Data("\u{1}\u{1f}gterm-scroll;3~".utf8))
        XCTAssertFalse(input.isActive)
        XCTAssertEqual(input.returnToLive(), Data())
    }

    func testNativeScrollIgnoresNewerDirectionAtLiveAndInvalidGeometry() {
        var input = ScreenScrollInput()
        XCTAssertEqual(input.scroll(points: -30, pointsPerLine: 10, historyLimit: 1000), Data())
        XCTAssertEqual(input.scroll(points: 10, pointsPerLine: 0, historyLimit: 1000), Data())
        XCTAssertEqual(input.scroll(points: .nan, pointsPerLine: 10, historyLimit: 1000), Data())
        XCTAssertFalse(input.isActive)
        XCTAssertEqual(input.scroll(points: 10, pointsPerLine: 10, historyLimit: 1000), Data("\u{1}\u{1f}gterm-scroll;0~\u{1}\u{1f}gterm-scroll;1~".utf8))
    }

    func testQuietTraversalIgnoresNumbersInsideTitles() throws {
        let start = try ScreenProtocol.firstWindow("8\u{1f}\u{1f}0 name  17 fake-window  8 real\u{1e}").first
        XCTAssertEqual(start, 0)
        XCTAssertThrowsError(try ScreenProtocol.firstWindow("0\u{1f}group\u{1f}0 shell\u{1e}").first)
        let next = try ScreenProtocol.windowAndNext("0\u{1f}*>\u{1f}name  17 fake-window\u{1e}  8 real\u{1e}")
        XCTAssertEqual(next.window.title, "name  17 fake-window")
        XCTAssertEqual(next.next, 8)
        XCTAssertTrue(next.window.selected)
        XCTAssertNil(try ScreenProtocol.windowAndNext("8\u{1f}\u{1f}real\u{1e}\u{1e}").next)
    }

    func testScreen4UnknownGroupEscapeIsNotAGroup() throws {
        XCTAssertEqual(try ScreenProtocol.firstWindow("8\u{1f}8g\u{1f}0 shell  8 work\u{1e}").first, 0)
        XCTAssertEqual(try ScreenProtocol.firstWindow("0\u{1f}0g\u{1f}0 shell\u{1e}").first, 0)
        XCTAssertThrowsError(try ScreenProtocol.firstWindow("8\u{1f}7g\u{1f}0 shell\u{1e}").first)
        XCTAssertThrowsError(try ScreenProtocol.firstWindow("bad\u{1f}\u{1f}0 shell\u{1e}").first)
    }

    func testWindowFlagsAndTitles() throws {
        let windows = try ScreenProtocol.windows("0\u{1f}*\u{1f}main shell\u{1e}\n12\u{1f}!@\u{1f}build 日本語\u{1e}")
        XCTAssertEqual(windows.map(\.number), [0, 12])
        XCTAssertTrue(windows[0].selected)
        XCTAssertTrue(windows[1].bell)
        XCTAssertTrue(windows[1].activity)
        XCTAssertEqual(windows[1].title, "build 日本語")
    }

    func testRejectsAmbiguousOrTruncatedRecords() {
        for text in ["", "0\u{1f}*\u{1f}name", "0\u{1f}*\u{1f}x\u{1e}0\u{1f}!\u{1f}y\u{1e}", "oops", "1\u{1f}*\u{1f}x\n2 other\u{1e}"] {
            XCTAssertThrowsError(try ScreenProtocol.windows(text), text)
        }
    }

    func testSessionDiscovery() throws {
        let list = try ScreenProtocol.sessions("There are screens on:\r\n\t1234.work\t(09/06/26 10:00:00)\t(Detached)\n\t5678.other\t(Attached)\n2 Sockets in /run/screen/S-user.\n")
        XCTAssertEqual(list.map(\.id), ["1234.work", "5678.other"])
        XCTAssertTrue(list[0].isDetached)
        XCTAssertFalse(list[1].isDetached)
        XCTAssertEqual(try ScreenProtocol.sessions("No Sockets found in /run/screen/S-user.\n"), [])
        XCTAssertThrowsError(try ScreenProtocol.sessions("Permission denied"))
    }

    func testDiscoversAttachedSessionFromFinney() throws {
        let output = "There is a screen on:\n        7080.pts-0.finney       (08/26/26 00:28:09)     (Attached)\n1 Socket in /run/screen/S-carback1.\n"
        let sessions = try ScreenProtocol.sessions(output)
        XCTAssertEqual(sessions, [ScreenSessionInfo(id: "7080.pts-0.finney", isDetached: false)])
        XCTAssertEqual(try ScreenProtocol.attachCommand(sessions[0].id), "exec screen -x '7080.pts-0.finney'")
    }

    func testShellQuotingAndValidation() throws {
        XCTAssertEqual(ScreenProtocol.quote("a'b"), "'a'\\''b'")
        XCTAssertThrowsError(try ScreenProtocol.command(session: "x\nquit", arguments: ["windows"], query: true))
        XCTAssertThrowsError(try ScreenProtocol.validTitle("$(touch /tmp/no)"))
        XCTAssertThrowsError(try ScreenProtocol.validTitle("one\ntwo"))
        XCTAssertEqual(try ScreenProtocol.validTitle("Build 2-日本語"), "Build 2-日本語")
        XCTAssertEqual(try ScreenProtocol.command(session: "12.work", window: 3, arguments: ["select", "3"], query: true), "LC_ALL=C screen -S '12.work' -p '3' -Q 'select' '3'")
    }
}
