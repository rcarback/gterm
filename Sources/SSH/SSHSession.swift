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
        lifecycle.setStopped(true)
        let group = self.group
        // Close port-forward listeners + tunnels FIRST and wait for them to be
        // fully released, THEN close the channels and shut the group down. Shutting
        // the group down concurrently can leave a listener lingering bound, so the
        // next session's bind fails with EADDRINUSE.
        let cleanup = forwardManager?.stopAll() ?? group.next().makeSucceededVoidFuture()
        forwardManager = nil
        let child = childChannel
        let transport = self.transport
        self.transport = nil
        childChannel = nil
        channel = nil
        ptyHandler = nil
        cleanup.whenComplete { _ in
            child?.close(promise: nil)
            let closed = transport?.close() ?? group.next().makeSucceededVoidFuture()
            closed.whenComplete { _ in group.shutdownGracefully { _ in } }
        }
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
