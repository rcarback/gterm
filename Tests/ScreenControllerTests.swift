import Foundation
import XCTest
import Combine

@MainActor
final class ScreenControllerTests: XCTestCase {
    func testDiscoverAndAttachAttachesOnlySession() async {
        var attachmentCommand: String?
        let model = ScreenController(execute: { command in
            if command.contains(ScreenProtocol.listCommand) {
                return screenList(("12.work", "Detached"))
            }
            return screenReply(command)
        }, attach: { attachmentCommand = $0 }, detach: {})

        await model.discoverAndAttachIfOnlySession()

        XCTAssertEqual(attachmentCommand, "exec screen -x '12.work'")
        XCTAssertEqual(model.sessionID, "12.work")
        XCTAssertEqual(model.sessions, [ScreenSessionInfo(id: "12.work", isDetached: true)])
        XCTAssertNil(model.errorMessage)
    }

    func testDiscoverAndAttachLeavesMultipleSessionsForSelection() async {
        var opened = false
        let model = ScreenController(execute: { command in
            if command.contains(ScreenProtocol.listCommand) {
                return screenList(("12.work", "Detached"), ("34.other", "Attached"))
            }
            return screenReply(command)
        }, attach: { _ in opened = true }, detach: {})

        await model.discoverAndAttachIfOnlySession()

        XCTAssertFalse(opened)
        XCTAssertNil(model.sessionID)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertNil(model.errorMessage)
    }

    func testDiscoverAndAttachLeavesEmptySessionListForSelection() async {
        var opened = false
        let model = ScreenController(execute: { command in
            if command.contains(ScreenProtocol.listCommand) {
                return "No Sockets found in /run/screen/S-user.\n"
            }
            return screenReply(command)
        }, attach: { _ in opened = true }, detach: {})

        await model.discoverAndAttachIfOnlySession()

        XCTAssertFalse(opened)
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testDiscoverAndAttachDoesNotUseSessionsFromFailedDiscovery() async {
        var failDiscovery = false
        var opened = false
        let model = ScreenController(execute: { command in
            if command.contains(ScreenProtocol.listCommand) {
                if failDiscovery { throw ScreenError(message: "Connection lost") }
                return screenList(("12.work", "Detached"))
            }
            return screenReply(command)
        }, attach: { _ in opened = true }, detach: {})
        await model.discover()
        failDiscovery = true

        await model.discoverAndAttachIfOnlySession()

        XCTAssertFalse(opened)
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.errorMessage?.contains("Connection lost") == true)
    }

    func testDiscoverAndAttachDoesNotAttachAfterDetachSupersedesDiscovery() async {
        var listCount = 0
        var continuation: CheckedContinuation<String, Error>?
        var opened = false
        let model = ScreenController(execute: { command in
            if command.contains(ScreenProtocol.listCommand) {
                listCount += 1
                if listCount == 1 { return screenList(("12.work", "Detached")) }
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return screenReply(command)
        }, attach: { _ in opened = true }, detach: {})
        await model.discover()
        let operation = Task { await model.discoverAndAttachIfOnlySession() }
        while continuation == nil { await Task.yield() }

        model.detach()
        continuation?.resume(returning: screenList(("34.new", "Detached")))
        await operation.value

        XCTAssertFalse(opened)
        XCTAssertNil(model.sessionID)
        XCTAssertEqual(model.sessions, [ScreenSessionInfo(id: "12.work", isDetached: true)])
    }

    func testReadsHistoryLimitForSelectedWindow() async throws {
        var historyCommand = ""
        let model = ScreenController(execute: { command in
            if command.contains("-Q 'info'") {
                historyCommand = command
                return "(1,20)/(80,24)+1024 +flow\ngterm-history-lines:1048\n"
            }
            return screenReply(command)
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: false))
        let limit = try await model.readHistoryLimit()
        XCTAssertEqual(limit, 1024)
        XCTAssertTrue(historyCommand.contains("LC_ALL=C screen -S '12.work' -p '0' -Q 'info'"))
        XCTAssertTrue(historyCommand.contains("LC_ALL=C screen -S '12.work' -p '0' -X 'hardcopy' '-h'"))
    }

    func testHistoryQueryFailureIsNotTreatedAsEmptyHistory() async {
        let model = ScreenController(execute: { command in
            if command.contains("-Q 'info'") { throw ScreenError(message: "Query failed") }
            return screenReply(command)
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: false))
        do {
            _ = try await model.readHistoryLimit()
            XCTFail("History query failure must be reported")
        } catch { XCTAssertEqual(error.localizedDescription, "Query failed") }
    }

    func testBindingFailureDoesNotOpenTerminal() async {
        var opened = false
        let model = ScreenController(execute: { command in
            if command.contains("'bindkey'") {
                throw ScreenError(message: "Binding installation failed")
            }
            return screenReply(command)
        }, attach: { _ in opened = true }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: false))
        XCTAssertFalse(opened)
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.errorMessage?.contains("Binding installation failed") == true)
    }

    func testUnchangedBackgroundRefreshDoesNotPublishOrBlockActions() async {
        let model = ScreenController(execute: { screenReply($0) }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        await model.refresh(background: true)
        XCTAssertEqual(updates, 0)
        XCTAssertTrue(model.canAct)
        withExtendedLifetime(subscription) {}
    }

    func testActionSupersedesPendingBackgroundRefresh() async {
        var pauseNext = false
        var continuation: CheckedContinuation<String, Error>?
        var title = "shell"
        let model = ScreenController(execute: { command in
            if pauseNext {
                pauseNext = false
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            if command.contains("-X 'title' 'new'") { title = "new"; return "" }
            return screenReply(command, title: title)
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        pauseNext = true
        let poll = Task { await model.refresh(background: true) }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(model.canAct)
        await model.rename(model.windows[0], title: "new")
        continuation?.resume(returning: "0\u{1f}\u{1f}0 shell\u{1e}")
        await poll.value
        XCTAssertEqual(model.windows.first?.title, "new")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canAct)
    }

    func testSelectWithoutSelectedFlag() async {
        var selected = 0
        let model = ScreenController(execute: { command in
            if command.contains("-Q 'select' '1'") { selected = 1; return "" }
            if command.contains(ScreenProtocol.firstWindowFormat) {
                return "\(selected)\u{1f}\(selected)g\u{1f}0 shell  1 work\u{1e}"
            }
            if command.contains("-p '1'") { return "1\u{1f}\u{1f}work\u{1e}\u{1e}" }
            return "0\u{1f}\u{1f}shell\u{1e}  1 work\u{1e}"
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: false))
        XCTAssertEqual(model.selectedWindow?.number, 0)
        await model.select(1)
        XCTAssertEqual(model.selectedWindow?.number, 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.canAct)
    }

    func testAddWindowRefreshesBeforeCheckingResult() async {
        var added = false
        let model = ScreenController(execute: { command in
            if command.contains("-X 'screen'") { added = true; return "" }
            if added && command.contains(ScreenProtocol.nextWindowFormat) {
                if command.contains("-p '1'") { return "1\u{1f}*\u{1f}new\u{1e}\u{1e}" }
                return "0\u{1f}\u{1f}shell\u{1e}  1 new\u{1e}"
            }
            return screenReply(command)
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        await model.addWindow(title: "new")
        XCTAssertEqual(model.windows.count, 2)
        XCTAssertNil(model.errorMessage)
    }

    func testAddWindowReportsNoNewWindow() async {
        let model = ScreenController(execute: { screenReply($0) }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        await model.addWindow(title: "new")
        XCTAssertNotNil(model.errorMessage)
    }

    func testExplicitDetachClosesOnlyOwnDisplay() async {
        var commands: [String] = []
        var closed = false
        let model = ScreenController(execute: { command in
            commands.append(command)
            return screenReply(command)
        }, attach: { _ in }, detach: { closed = true })
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        model.detach()
        XCTAssertFalse(commands.contains { $0.contains("detach") })
        XCTAssertTrue(closed)
        XCTAssertNil(model.sessionID)
    }

    func testInvalidProbeDoesNotOpenTerminal() async {
        var opened = false
        let model = ScreenController(execute: { _ in "unsupported format" }, attach: { _ in opened = true }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        XCTAssertFalse(opened)
        XCTAssertNil(model.sessionID)
    }

    func testRenameRejectsWindowReusedSinceConfirmation() async {
        var title = "old"
        var commands: [String] = []
        let model = ScreenController(execute: { command in
            commands.append(command)
            return screenReply(command, title: title)
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        let window = model.windows[0]
        title = "replacement"
        await model.rename(window, title: "renamed")
        XCTAssertFalse(commands.contains { $0.contains("-X 'title'") })
        XCTAssertNotNil(model.errorMessage)
    }

    func testRenameReportsRejectedRemoteChange() async {
        let model = ScreenController(execute: { screenReply($0, title: "old") }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        await model.rename(model.windows[0], title: "new")
        XCTAssertNotNil(model.errorMessage)
    }

    func testSharesAttachedSession() async {
        var attachmentCommand: String?
        let model = ScreenController(execute: { screenReply($0) }, attach: { attachmentCommand = $0 }, detach: {})
        await model.attach(ScreenSessionInfo(id: "1.busy", isDetached: false))
        XCTAssertEqual(attachmentCommand, "exec screen -x '1.busy'")
        XCTAssertEqual(model.sessionID, "1.busy")
        XCTAssertTrue(model.canAct)
        XCTAssertNil(model.errorMessage)
    }

    func testAttachLoadsTabsAndDetachPreservesRemoteSession() async {
        var commands: [String] = []
        var closed = false
        let model = ScreenController(execute: { command in
            commands.append(command)
            return screenReply(command)
        }, attach: { _ in }, detach: { closed = true })
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        XCTAssertEqual(model.windows.first?.title, "shell")
        XCTAssertTrue(model.canAct)
        model.detach()
        XCTAssertTrue(closed)
        XCTAssertNil(model.sessionID)
        XCTAssertFalse(commands.contains { $0.contains("quit") || $0.contains("kill") })
    }

    func testFailedRefreshDisablesMutation() async {
        var fail = false
        var commands: [String] = []
        let model = ScreenController(execute: { command in
            commands.append(command)
            if fail { throw ScreenError(message: "Connection lost") }
            return screenReply(command)
        }, attach: { _ in }, detach: {})
        await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true))
        fail = true
        await model.refresh()
        let count = commands.count
        await model.select(0)
        XCTAssertEqual(commands.count, count)
        XCTAssertFalse(model.canAct)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLateRefreshCannotRestoreDetachedState() async {
        var continuation: CheckedContinuation<String, Error>?
        let model = ScreenController(execute: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }, attach: { _ in }, detach: {})
        let operation = Task { await model.attach(ScreenSessionInfo(id: "12.work", isDetached: true)) }
        while continuation == nil { await Task.yield() }
        model.detach()
        continuation?.resume(returning: "0\u{1f}*\u{1f}shell\u{1e}")
        await operation.value
        XCTAssertNil(model.sessionID)
        XCTAssertTrue(model.windows.isEmpty)
    }
}

private func screenReply(_ command: String, title: String = "shell") -> String {
    if command.contains(ScreenProtocol.firstWindowFormat) { return "0\u{1f}\u{1f}0 \(title)\u{1e}" }
    return "0\u{1f}*\u{1f}\(title)\u{1e}\u{1e}"
}

private func screenList(_ sessions: (id: String, state: String)...) -> String {
    let rows = sessions.map { "\t\($0.id)\t(09/06/26 10:00:00)\t(\($0.state))" }.joined(separator: "\n")
    return "There are screens on:\n\(rows)\n\(sessions.count) Sockets in /run/screen/S-user.\n"
}
