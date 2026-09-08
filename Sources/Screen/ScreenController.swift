import Foundation
import Combine

@MainActor
final class ScreenController: ObservableObject {
    @Published private(set) var sessions: [ScreenSessionInfo] = []
    @Published private(set) var sessionID: String?
    @Published private(set) var windows: [ScreenWindow] = []
    @Published private(set) var busy = false
    @Published private(set) var stale = true
    @Published var errorMessage: String?

    private let execute: (String) async throws -> String
    private let openTerminal: (String) async throws -> Void
    private let closeTerminal: () -> Void
    private var generation = 0
    private var polling = false

    var selectedWindow: ScreenWindow? { windows.first(where: \.selected) }
    var canAct: Bool { sessionID != nil && !busy && !stale }

    init(execute: @escaping (String) async throws -> String,
         attach: @escaping (String) async throws -> Void,
         detach: @escaping () -> Void) {
        self.execute = execute
        self.openTerminal = attach
        self.closeTerminal = detach
    }

    func discover() async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            // Screen returns 1 for an empty list. Preserve other failures.
            let output = try await execute(ScreenProtocol.listCommand + "; gterm_status=$?; if [ \"$gterm_status\" -eq 1 ]; then exit 0; else exit \"$gterm_status\"; fi")
            guard token == generation else { return }
            sessions = try ScreenProtocol.sessions(output)
        } catch {
            guard token == generation else { return }
            sessions = []
            errorMessage = "List Screen sessions: " + error.localizedDescription
        }
    }

    func discoverAndAttachIfOnlySession() async {
        guard !busy, sessionID == nil else { return }
        let token = generation
        await discover()
        guard token == generation, errorMessage == nil, sessions.count == 1,
              let session = sessions.first else { return }
        await attach(session)
    }

    func attach(_ session: ScreenSessionInfo) async {
        guard !busy, sessionID == nil else { return }
        busy = true
        errorMessage = nil
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            let command = try ScreenProtocol.attachCommand(session.id)
            // Probe query support before opening the terminal.
            _ = try await fetchWindows(session: session.id, token: token)
            guard token == generation else { return }
            for binding in try ScreenProtocol.scrollBindingCommands(session: session.id) {
                _ = try await execute(binding)
                guard token == generation else { return }
            }
            try await openTerminal(command)
            guard token == generation else { closeTerminal(); return }
            sessionID = session.id
            try await readWindows(session: session.id, token: token)
        } catch {
            guard token == generation else { return }
            errorMessage = "Attach Screen: " + error.localizedDescription
            stale = true
        }
    }

    func readHistoryLimit() async throws -> Int {
        guard let sessionID, let window = selectedWindow else {
            throw ScreenError(message: "Select a Screen window before scrolling.")
        }
        let token = generation
        let command = try ScreenProtocol.historyLimitCommand(session: sessionID, window: window.number)
        let output = try await execute(command)
        guard token == generation, self.sessionID == sessionID,
              selectedWindow?.number == window.number else { throw CancellationError() }
        return try ScreenProtocol.historyLimit(output)
    }

    func detach() {
        generation += 1
        closeTerminal()
        sessionID = nil
        windows = []
        stale = true
        busy = false
    }

    func terminalClosed(_ error: Error?) {
        detach()
        if let error { errorMessage = "Screen terminal closed: " + error.localizedDescription }
    }

    func refresh(background: Bool = false) async {
        guard let sessionID, !busy else { return }
        if background && polling { return }
        if background {
            polling = true
        } else {
            generation += 1
            busy = true
        }
        let token = generation
        defer {
            if background { polling = false }
            else if token == generation { busy = false }
        }
        do {
            try await readWindows(session: sessionID, token: token)
        } catch {
            guard token == generation else { return }
            stale = true
            errorMessage = "Refresh Screen: " + error.localizedDescription
        }
    }

    func select(_ number: Int) async {
        guard let window = windows.first(where: { $0.number == number }) else { return }
        await mutate(window: window, arguments: ["select", String(number)], query: true)
    }

    func addWindow(title: String) async {
        do { await mutate(arguments: ["screen", "-t", try ScreenProtocol.validTitle(title)]) }
        catch { errorMessage = error.localizedDescription }
    }

    func rename(_ window: ScreenWindow, title: String) async {
        do { await mutate(window: window, arguments: ["title", try ScreenProtocol.validTitle(title)]) }
        catch { errorMessage = error.localizedDescription }
    }

    func close(_ window: ScreenWindow) async {
        await mutate(window: window, arguments: ["kill"])
    }

    func monitor(_ window: ScreenWindow, enabled: Bool) async {
        await mutate(window: window, arguments: ["monitor", enabled ? "on" : "off"])
    }

    private func mutate(window: ScreenWindow? = nil, arguments: [String], query: Bool = false) async {
        guard canAct, let sessionID else { return }
        if let window, !windows.contains(where: { $0.number == window.number && $0.title == window.title }) {
            errorMessage = "The window changed. Refresh and select it again."
            return
        }
        generation += 1
        busy = true
        errorMessage = nil
        let token = generation
        defer { if token == generation { busy = false } }
        do {
            try await readWindows(session: sessionID, token: token)
            guard token == generation else { return }
            if let window, !windows.contains(where: { $0.number == window.number && $0.title == window.title }) {
                throw ScreenError(message: "The window changed. Select it again before repeating the action.")
            }
            let previousNumbers = Set(windows.map(\.number))
            _ = try await execute(ScreenProtocol.command(session: sessionID, window: window?.number, arguments: arguments, query: query))
            guard token == generation else { return }
            try await readWindows(session: sessionID, token: token)
            guard token == generation else { return }
            if arguments.first == "screen", windows.allSatisfy({ previousNumbers.contains($0.number) }) {
                throw ScreenError(message: "No new Screen window appeared. Check the window limit and remote permissions.")
            }
            if arguments.first == "title", let window,
               windows.first(where: { $0.number == window.number })?.title != arguments.last {
                throw ScreenError(message: "Screen did not rename the window. Check remote permissions and retry.")
            }
            if arguments.first == "select", selectedWindow?.number != window?.number {
                throw ScreenError(message: "Screen did not select the window. Refresh and retry.")
            }
            if arguments.first == "kill", let window, windows.contains(where: { $0.number == window.number }) {
                throw ScreenError(message: "Screen did not close the window. Refresh and check its state.")
            }
        } catch {
            guard token == generation else { return }
            stale = true
            errorMessage = "Screen action: " + error.localizedDescription
        }
    }

    private func readWindows(session: String, token: Int) async throws {
        let result = try await fetchWindows(session: session, token: token)
        guard token == generation else { return }
        if windows != result { windows = result }
        if stale { stale = false }
        if errorMessage != nil { errorMessage = nil }
    }

    private func fetchWindows(session: String, token: Int) async throws -> [ScreenWindow] {
        let initial = try await execute(ScreenProtocol.command(session: session, arguments: ["@echo", "-p", ScreenProtocol.firstWindowFormat], query: true))
        guard token == generation else { throw CancellationError() }
        let context = try ScreenProtocol.firstWindow(initial)
        var next: Int? = context.first
        var result: [ScreenWindow] = []
        // Only the first number of %w/%+w is used. Titles may contain spaces and
        // the remainder may truncate. Quiet @echo bypasses Screen's status line.
        while let number = next {
            guard result.count < 256, !result.contains(where: { $0.number == number }) else {
                throw ScreenError(message: "Screen windows changed during refresh. Refresh again.")
            }
            let output = try await execute(ScreenProtocol.command(session: session, window: number, arguments: ["@echo", "-p", ScreenProtocol.nextWindowFormat], query: true))
            guard token == generation else { throw CancellationError() }
            let record = try ScreenProtocol.windowAndNext(output)
            guard record.window.number == number else { throw ScreenError(message: "Screen returned a different window. Refresh again.") }
            // %f omits the selected flag on Screen 4. The unqualified %n query
            // identifies the foreground window independently of per-window flags.
            let flags = record.window.flags.replacingOccurrences(of: "*", with: "")
                + (number == context.selected ? "*" : "")
            result.append(ScreenWindow(number: number, title: record.window.title, flags: flags))
            next = record.next
        }
        guard result.filter(\.selected).count == 1 else {
            throw ScreenError(message: "Screen windows changed or use window groups. Refresh, or use a session without groups.")
        }
        return result.sorted { $0.number < $1.number }
    }
}
