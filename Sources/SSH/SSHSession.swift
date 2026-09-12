import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Drives an interactive SSH shell over a PTY using swift-nio-ssh and feeds it
/// into a TerminalSurfaceView. It is the surface's delegate: user input flows
/// out to the channel, server output flows into the surface, and resizes are
/// forwarded as window-change requests.
final class SSHSession: TerminalSession {
    private let connection: SSHConnection
    private weak var view: TerminalSurfaceView?
    private let lifecycle: SessionStateNotifier
    private let onHostKeyPrompt: TOFUHostKeyDelegate.Prompt?

    private let group: EventLoopGroup
    private var transport: SSHTransport?
    private var channel: Channel?
    private var childChannel: Channel?
    private var ptyHandler: PTYChannelHandler?
    private var keepalive: SSHKeepalive?

    private let stopLock = NSLock()
    private var stopStarted = false
    private var stopFinished = false
    private var stopCompletions: [() -> Void] = []

    private var forwardManager: PortForwardManager?
    private let forwards: [PortForward]
    private let onForwardChange: ((UUID, PortForwardStatus) -> Void)?

    init(
        connection: SSHConnection,
        view: TerminalSurfaceView,
        forwards: [PortForward] = [],
        onHostKeyPrompt: TOFUHostKeyDelegate.Prompt? = nil,
        onForwardChange: ((UUID, PortForwardStatus) -> Void)? = nil,
        onStateChange: @escaping (SSHSessionState) -> Void
    ) {
        self.connection = connection
        self.view = view
        self.forwards = forwards
        self.onHostKeyPrompt = onHostKeyPrompt
        self.onForwardChange = onForwardChange
        self.lifecycle = SessionStateNotifier(onStateChange: onStateChange)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    // MARK: TerminalSession

    func start() {
        lifecycle.setStopped(false)
        lifecycle.notify(.connecting)

        let transport = SSHTransport(group: group, onHostKeyPrompt: onHostKeyPrompt)
        self.transport = transport
        lifecycle.notify(.authenticating)
        transport.connect(connection).whenComplete { [weak self] result in
            guard let self else { return }
            if self.lifecycle.isStopped() { return }
            switch result {
            case .failure(let error):
                _ = self.transport?.close()
                self.lifecycle.notify(.failed(Self.describe(error)))
            case .success(let channel):
                self.channel = channel
                self.openShellChannel(on: channel)
            }
        }
    }

    func stop() {
        beginStop()
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            beginStop { continuation.resume() }
        }
    }

    private func beginStop(completion: (() -> Void)? = nil) {
        lifecycle.setStopped(true)
        stopLock.lock()
        if stopFinished {
            stopLock.unlock()
            completion?()
            return
        }
        if let completion { stopCompletions.append(completion) }
        guard !stopStarted else {
            stopLock.unlock()
            return
        }
        stopStarted = true
        let manager = forwardManager
        forwardManager = nil
        let child = childChannel
        let transport = self.transport
        let keepalive = self.keepalive
        self.transport = nil
        childChannel = nil
        channel = nil
        ptyHandler = nil
        self.keepalive = nil
        stopLock.unlock()
        keepalive?.stop()

        let group = self.group
        // Close port-forward listeners + tunnels FIRST and wait for them to be
        // fully released, THEN close the channels and shut the group down. Shutting
        // the group down concurrently can leave a listener lingering bound, so the
        // next session's bind fails with EADDRINUSE.
        let cleanup = manager?.stopAll() ?? group.next().makeSucceededVoidFuture()
        cleanup.whenComplete { _ in
            let childClosed = child?.close().recover { _ in () }
                ?? group.next().makeSucceededVoidFuture()
            let closed = transport?.close() ?? group.next().makeSucceededVoidFuture()
            EventLoopFuture.andAllComplete([childClosed, closed], on: group.next()).whenComplete { _ in
                group.shutdownGracefully { [self] _ in finishStop() }
            }
        }
    }

    private func finishStop() {
        stopLock.lock()
        guard !stopFinished else {
            stopLock.unlock()
            return
        }
        stopFinished = true
        let completions = stopCompletions
        stopCompletions.removeAll()
        stopLock.unlock()
        for completion in completions { completion() }
    }

    // MARK: Open the PTY shell child channel

    private func openShellChannel(on channel: Channel) {
        if lifecycle.isStopped() {
            channel.close(promise: nil)
            return
        }
        let (cols, rows) = view?.gridSize ?? (80, 24)

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            if self.lifecycle.isStopped() {
                channel.close(promise: nil)
                return
            }
            switch result {
            case .failure(let error):
                _ = self.transport?.close()
                self.lifecycle.notify(.failed(Self.describe(error)))

            case .success(let sshHandler):
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
                    let pty = PTYChannelHandler(
                        term: self.connection.term,
                        cols: cols,
                        rows: rows,
                        start: HerdrSupport.ptyStart(attachHerdr: self.connection.attachHerdr),
                        onOutput: { [weak self] buf in
                            self?.deliverOutput(buf)
                        },
                        onClose: { [weak self] error in
                            self?.handleChannelClose(error)
                        }
                    )
                    self.ptyHandler = pty
                    return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .flatMap {
                            childChannel.pipeline.addHandler(pty)
                        }
                }

                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    if self.lifecycle.isStopped() {
                        if case .success(let child) = result { child.close(promise: nil) }
                        return
                    }
                    switch result {
                    case .failure(let error):
                        _ = self.transport?.close()
                        self.lifecycle.notify(.failed(Self.describe(error)))
                    case .success(let childChannel):
                        self.stopLock.lock()
                        guard !self.stopStarted else {
                            self.stopLock.unlock()
                            childChannel.close(promise: nil)
                            return
                        }
                        self.childChannel = childChannel
                        // The parent `channel` is the authenticated connection;
                        // the forward manager reuses it and the shared group.
                        let mgr = PortForwardManager(
                            parentChannel: channel,
                            group: self.group,
                            onChange: { [weak self] id, st in self?.onForwardChange?(id, st) }
                        )
                        self.forwardManager = mgr
                        for f in self.forwards where f.autoStart { mgr.start(f) }
                        let keepalive = SSHKeepalive(channel: channel) { [weak self] in
                            self?.handleChannelClose(SSHExecError.keepaliveTimedOut)
                        }
                        self.keepalive = keepalive
                        self.stopLock.unlock()
                        keepalive.start()
                        self.lifecycle.notify(.connected)
                    }
                }
            }
        }
    }

    // MARK: Port forwarding

    /// Start the listener for the forward with `id` (looked up in the stored
    /// configs). The manager hops to the event loop internally.
    func startForward(_ id: UUID) {
        guard let f = forwards.first(where: { $0.id == id }) else { return }
        forwardManager?.start(f)
    }

    func stopForward(_ id: UUID) {
        forwardManager?.stop(id)
    }

    // MARK: Command channels

    /// Run a non-interactive command on a separate authenticated child channel.
    /// Command bytes and output never pass through the interactive shell channel.
    func execute(_ command: String) async throws -> String {
        try await execute(command, timeout: .seconds(10))
    }

    /// Prove the connection round-trips. A keepalive is one packet and needs no
    /// child channel, so a stalled socket fails faster than an exec probe and a
    /// healthy one is not disturbed at all.
    func checkConnection() async throws {
        guard let keepalive else { throw SSHExecError.notConnected }
        try await keepalive.probe(timeout: .seconds(3)).get()
    }

    private func execute(_ command: String, timeout: TimeAmount) async throws -> String {
        guard let channel, channel.isActive else { throw SSHExecError.notConnected }
        let request = SSHExecOperation(parentChannel: channel, command: command, timeout: timeout)
        request.start()
        return try await withTaskCancellationHandler(operation: {
            try await request.result.get()
        }, onCancel: {
            request.cancel()
        })
    }

    /// Open an interactive Screen attachment on its own PTY child channel.
    /// The returned terminal is ready only after the server accepts both the
    /// PTY allocation and exec request.
    @MainActor
    func openScreenTerminal(
        command: String,
        view: TerminalSurfaceView,
        onClose: @escaping (Error?) -> Void
    ) async throws -> ScreenTerminal {
        guard let channel, channel.isActive else { throw SSHExecError.notConnected }
        let gridSize = view.gridSize
        let request = ScreenTerminalOpenOperation(
            parentChannel: channel,
            term: connection.term,
            command: command,
            view: view,
            cols: gridSize.cols,
            rows: gridSize.rows,
            timeout: .seconds(10),
            onClose: onClose
        )
        request.start()
        let terminal = try await withTaskCancellationHandler(operation: {
            try await request.result.get()
        }, onCancel: {
            request.cancel()
        })
        view.delegate = terminal
        return terminal
    }

    private func deliverOutput(_ buf: ByteBuffer) {
        guard let view else { return }
        var buf = buf
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            view.receive(Data(bytes))
        }
    }

    private func handleChannelClose(_ error: Error?) {
        _ = transport?.close()
        if let error {
            lifecycle.notify(.failed(Self.describe(error)))
        } else {
            lifecycle.notify(.closed)
        }
    }

    // MARK: TerminalSurfaceViewDelegate

    func terminalSurface(_ view: TerminalSurfaceView, didProduceOutput data: Data) {
        guard let childChannel else { return }
        var buf = childChannel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        childChannel.eventLoop.execute {
            childChannel.writeAndFlush(buf, promise: nil)
        }
    }

    func terminalSurface(_ view: TerminalSurfaceView, didResizeToCols cols: Int, rows: Int) {
        guard let childChannel, let ptyHandler else { return }
        childChannel.eventLoop.execute {
            ptyHandler.sendWindowChange(cols: cols, rows: rows)
        }
    }

    func terminalSurfaceDidResume(_ view: TerminalSurfaceView, cols: Int, rows: Int) {
        guard let childChannel, let ptyHandler else { return }
        let sizes = HerdrSupport.windowChangesForForeground(
            attachHerdr: connection.attachHerdr, cols: cols, rows: rows
        )
        childChannel.eventLoop.execute {
            for size in sizes {
                ptyHandler.sendWindowChange(cols: size.cols, rows: size.rows)
            }
        }
    }

    // MARK: Helpers

    private static func describe(_ error: Error) -> String {
        if let keyError = error as? SSHKeyError {
            return keyError.description
        }
        if let hostKey = error as? HostKeyError {
            return hostKey.description
        }
        if let sshError = error as? NIOSSHError {
            return "\(sshError)"
        }
        return error.localizedDescription
    }
}

/// Routes a dedicated Screen PTY without replacing the session's primary shell.
final class ScreenTerminal: TerminalSurfaceViewDelegate, @unchecked Sendable {
    private let childChannel: Channel
    private weak var view: TerminalSurfaceView?
    private var ptyHandler: PTYChannelHandler?
    private let closeRelay: ScreenTerminalCloseRelay

    init(childChannel: Channel, view: TerminalSurfaceView, onClose: @escaping (Error?) -> Void) {
        self.childChannel = childChannel
        self.view = view
        self.closeRelay = ScreenTerminalCloseRelay(view: view, onClose: onClose)
        self.closeRelay.terminal = self
    }

    func configure(
        term: String,
        command: String,
        cols: Int,
        rows: Int,
        onReady: @escaping (Result<Void, Error>) -> Void
    ) -> EventLoopFuture<Void> {
        let handler = PTYChannelHandler(
            term: term,
            cols: cols,
            rows: rows,
            start: .exec(command),
            onOutput: { [weak self] buffer in self?.deliverOutput(buffer) },
            onReady: onReady,
            onClose: { [closeRelay] error in closeRelay.deliver(error) }
        )
        ptyHandler = handler
        return childChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            self.childChannel.pipeline.addHandler(handler)
        }
    }

    func close() {
        childChannel.eventLoop.execute {
            self.childChannel.close(promise: nil)
        }
    }

    func terminalSurface(_ view: TerminalSurfaceView, didProduceOutput data: Data) {
        sendInput(data)
    }

    func sendInput(_ data: Data) {
        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        childChannel.eventLoop.execute {
            self.childChannel.writeAndFlush(buffer, promise: nil)
        }
    }

    func terminalSurface(_ view: TerminalSurfaceView, didResizeToCols cols: Int, rows: Int) {
        childChannel.eventLoop.execute {
            self.ptyHandler?.sendWindowChange(cols: cols, rows: rows)
        }
    }

    private func deliverOutput(_ buffer: ByteBuffer) {
        var buffer = buffer
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        view?.receive(Data(bytes))
    }
}

private final class ScreenTerminalCloseRelay: @unchecked Sendable {
    weak var terminal: ScreenTerminal?
    private weak var view: TerminalSurfaceView?
    private var onClose: ((Error?) -> Void)?

    init(view: TerminalSurfaceView, onClose: @escaping (Error?) -> Void) {
        self.view = view
        self.onClose = onClose
    }

    func deliver(_ error: Error?) {
        guard let onClose else { return }
        self.onClose = nil
        DispatchQueue.main.async { [weak self] in
            if let terminal = self?.terminal, self?.view?.delegate === terminal {
                self?.view?.delegate = nil
            }
            onClose(error)
        }
    }
}

private final class ScreenTerminalOpenOperation {
    private let parentChannel: Channel
    private let term: String
    private let command: String
    private let view: TerminalSurfaceView
    private let cols: Int
    private let rows: Int
    private let timeout: TimeAmount
    private let onClose: (Error?) -> Void
    private let resultPromise: EventLoopPromise<ScreenTerminal>
    private var terminal: ScreenTerminal?
    private var childChannelOpened = false
    private var requestsAccepted = false
    private var timeoutTask: Scheduled<Void>?
    private var completed = false

    init(
        parentChannel: Channel,
        term: String,
        command: String,
        view: TerminalSurfaceView,
        cols: Int,
        rows: Int,
        timeout: TimeAmount,
        onClose: @escaping (Error?) -> Void
    ) {
        self.parentChannel = parentChannel
        self.term = term
        self.command = command
        self.view = view
        self.cols = cols
        self.rows = rows
        self.timeout = timeout
        self.onClose = onClose
        self.resultPromise = parentChannel.eventLoop.makePromise(of: ScreenTerminal.self)
    }

    var result: EventLoopFuture<ScreenTerminal> { resultPromise.futureResult }

    func start() {
        parentChannel.eventLoop.execute {
            guard !self.completed else { return }
            self.timeoutTask = self.parentChannel.eventLoop.scheduleTask(in: self.timeout) {
                self.finish(.failure(SSHExecError.timedOut))
            }
            self.parentChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { lookup in
                switch lookup {
                case .failure(let error):
                    self.finish(.failure(SSHExecError.channelOpenFailed(error.localizedDescription)))
                case .success(let sshHandler):
                    let channelPromise = self.parentChannel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(channelPromise, channelType: .session) { child, _ in
                        let terminal = ScreenTerminal(childChannel: child, view: self.view, onClose: self.onClose)
                        self.terminal = terminal
                        if self.completed {
                            child.close(promise: nil)
                            return child.eventLoop.makeFailedFuture(SSHExecError.cancelled)
                        }
                        return terminal.configure(
                            term: self.term,
                            command: self.command,
                            cols: self.cols,
                            rows: self.rows
                        ) { [weak self] ready in
                            guard let self else { return }
                            switch ready {
                            case .success:
                                self.requestsAccepted = true
                                self.succeedIfReady()
                            case .failure(let error):
                                self.finish(.failure(error))
                            }
                        }
                    }
                    channelPromise.futureResult.whenComplete { opened in
                        switch opened {
                        case .failure(let error):
                            self.finish(.failure(SSHExecError.channelOpenFailed(error.localizedDescription)))
                        case .success:
                            self.childChannelOpened = true
                            self.succeedIfReady()
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        finish(.failure(SSHExecError.cancelled))
    }

    private func succeedIfReady() {
        guard childChannelOpened, requestsAccepted, let terminal else { return }
        finish(.success(terminal))
    }

    private func finish(_ result: Result<ScreenTerminal, Error>) {
        guard parentChannel.eventLoop.inEventLoop else {
            parentChannel.eventLoop.execute { self.finish(result) }
            return
        }
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure = result { terminal?.close() }
        resultPromise.completeWith(result)
    }
}
