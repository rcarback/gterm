import SwiftUI

/// A live terminal session — the `SSHSession` transport plus the ghostty
/// `TerminalSurfaceView` it renders into — owned independently of any screen.
/// Because both halves are retained here, dismissing the terminal UI leaves
/// the SSH connection running and the scrollback intact; reopening the host
/// reattaches the same surface.
@MainActor
final class ActiveSession: ObservableObject, Identifiable {
    /// Keyed by the saved host so a host has at most one live session.
    let id: UUID
    let connection: SSHConnection
    let surface: TerminalSurfaceView
    private(set) var ssh: SSHSession!

    private let forwards: [PortForward]
    private var generation = 0
    private var explicitlyStopped = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundForwardIDs: Set<UUID>?
    @Published private(set) var isRecoveringConnection = false
    private lazy var recovery = SessionRecovery(check: { [weak self] in
        guard let self, self.state == .connected else { throw SSHExecError.notConnected }
        try await self.ssh.checkConnection()
    }, reconnect: { [weak self] in
        await self?.replaceTransport()
    })

    @Published private(set) var state: SSHSessionState = .idle
    @Published var forwardStates: [UUID: PortForwardStatus] = [:]
    /// A pending host-key trust decision, surfaced by whichever screen is
    /// currently showing this session.
    @Published var hostKeyRequest: HostKeyPromptRequest?

    init(connection: SSHConnection, ghostty: Ghostty.App, forwards: [PortForward]) {
        self.id = connection.savedID ?? connection.id
        self.connection = connection
        let surface = TerminalSurfaceView(ghostty: ghostty)
        surface.attachHerdr = connection.attachHerdr
        self.surface = surface
        self.forwards = forwards
        installTransport(forwards: forwards)
    }

    deinit { ssh?.stop() }

    private func installTransport(forwards: [PortForward]) {
        let token = generation
        let session = SSHSession(
            connection: connection,
            view: surface,
            forwards: forwards,
            onHostKeyPrompt: { [weak self] prompt, decide in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { decide(false); return }
                    self.hostKeyRequest = HostKeyPromptRequest(prompt: prompt, decide: decide)
                }
            },
            onForwardChange: { [weak self] id, status in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.forwardStates[id] = status
                }
            }
        ) { [weak self] newState in
            guard let self, self.generation == token else { return }
            self.state = newState
            switch newState {
            case .connected, .failed, .closed: self.finishWaitingForConnection()
            default: break
            }
        }
        ssh = session
        surface.delegate = session
    }

    private func finishWaitingForConnection() {
        let waiting = readyWaiters
        readyWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func enteredBackground() {
        guard !explicitlyStopped, isAlive || isRecoveringConnection else { return }
        if backgroundForwardIDs == nil {
            backgroundForwardIDs = Set(forwardStates.compactMap { id, status in
                status != .stopped ? id : nil
            })
        }
        isRecoveringConnection = true
        recovery.enteredBackground()
    }

    func resumeAfterBackground() async {
        guard !explicitlyStopped else { return }
        repeat {
            await recovery.resume()
        } while recovery.isPending && UIApplication.shared.applicationState == .active
            && !explicitlyStopped && !Task.isCancelled
        if !recovery.isPending {
            isRecoveringConnection = false
            backgroundForwardIDs = nil
        }
    }

    func reconnect() async {
        guard !explicitlyStopped else { return }
        if isRecoveringConnection { await resumeAfterBackground(); return }
        isRecoveringConnection = true
        recovery.enteredBackground()
        await resumeAfterBackground()
    }

    private func replaceTransport() async {
        guard !explicitlyStopped, !Task.isCancelled else { return }
        let enabled = backgroundForwardIDs ?? Set(forwardStates.compactMap { id, status in
            status != .stopped ? id : nil
        })
        generation += 1
        let token = generation
        state = .connecting
        hostKeyRequest?.decide(false)
        hostKeyRequest = nil
        surface.delegate = nil
        await ssh.stopAndWait()
        guard generation == token, !explicitlyStopped, !Task.isCancelled else { return }
        forwardStates = [:]
        let restoredForwards = forwards.map { forward in
            var restored = forward
            restored.autoStart = enabled.contains(forward.id)
            return restored
        }
        installTransport(forwards: restoredForwards)
        // Reset the local emulator for the new primary shell, without sending input.
        surface.receive(Data("\u{1b}c".utf8))
        ssh.start()
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// Whether the transport is (or may still become) usable. Failed and
    /// closed sessions are dead: they are pruned rather than kept around.
    var isAlive: Bool {
        switch state {
        case .failed, .closed: return false
        case .idle, .connecting, .authenticating, .connected: return true
        }
    }

    func start() {
        ssh.start()
    }

    /// Tear down the transport. `SSHSession.stop()` closes channels without a
    /// state callback, so mark the session closed here.
    func stop() {
        explicitlyStopped = true
        generation += 1
        recovery.cancel()
        isRecoveringConnection = false
        hostKeyRequest?.decide(false)
        hostKeyRequest = nil
        finishWaitingForConnection()
        ssh.stop()
        state = .closed
    }
}

/// Owns every `ActiveSession`, keeping connections alive while the user is
/// back in the main UI. The Hosts list uses it to show live status, reattach,
/// and disconnect.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [ActiveSession] = []

    func session(for id: UUID) -> ActiveSession? {
        sessions.first { $0.id == id }
    }

    /// Reattach to the live session for this connection, or start a new one.
    /// A dead leftover (failed / closed while backgrounded) is replaced.
    func open(
        _ connection: SSHConnection,
        ghostty: Ghostty.App,
        forwards: [PortForward]
    ) -> ActiveSession {
        let key = connection.savedID ?? connection.id
        if let existing = session(for: key) {
            if existing.isAlive { return existing }
            remove(existing)
        }
        let session = ActiveSession(connection: connection, ghostty: ghostty, forwards: forwards)
        sessions.append(session)
        session.start()
        return session
    }

    func enteredBackground() {
        sessions.forEach { $0.enteredBackground() }
    }

    func resumeAfterBackground() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.resumeAfterBackground() }
            }
        }
    }

    func disconnect(_ session: ActiveSession) {
        session.stop()
        remove(session)
    }

    /// Called when the terminal screen is dismissed: live sessions keep
    /// running in the background, dead ones are dropped so the next tap on
    /// the host reconnects fresh.
    func pruneIfDead(_ session: ActiveSession) {
        if !session.isAlive { remove(session) }
    }

    private func remove(_ session: ActiveSession) {
        sessions.removeAll { $0.id == session.id }
    }
}
