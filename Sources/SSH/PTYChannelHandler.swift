import NIOCore
import NIOSSH

/// Handles a single SSH "session" child channel running an interactive shell on
/// a PTY. On activation it requests a pseudo-terminal and a shell, then pipes
/// raw bytes both ways:
///   * inbound  SSHChannelData (server stdout/stderr) -> onOutput (to terminal)
///   * outbound bytes (keyboard/responses)            -> SSHChannelData (write)
/// Window resizes are sent as window-change requests.
final class PTYChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let term: String
    private var cols: Int
    private var rows: Int
    private let command: String?
    /// Called with bytes received from the server. Invoked on the channel's
    /// event loop.
    private let onOutput: (ByteBuffer) -> Void
    /// Called after the server accepts both the PTY and shell or exec request.
    private var onReady: ((Result<Void, Error>) -> Void)?
    /// Called when the shell channel closes / errors.
    private let onClose: (Error?) -> Void

    private var context: ChannelHandlerContext?
    private var closeOnce = ChannelCloseOnce()
    private var remoteCloseError: Error?

    init(
        term: String,
        cols: Int,
        rows: Int,
        command: String? = nil,
        onOutput: @escaping (ByteBuffer) -> Void,
        onReady: ((Result<Void, Error>) -> Void)? = nil,
        onClose: @escaping (Error?) -> Void
    ) {
        self.term = term
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.command = command
        self.onOutput = onOutput
        self.onReady = onReady
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        // Request a PTY, then a shell. wantReply so we learn of failures.
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 1, .ICANON: 1, .ISIG: 1])
        )
        context.triggerUserOutboundEvent(ptyRequest, promise: nil)

        if let command {
            let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            context.triggerUserOutboundEvent(execRequest, promise: nil)
        } else {
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            context.triggerUserOutboundEvent(shellRequest, promise: nil)
        }

        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        deliverReady(.failure(SSHExecError.disconnected))
        closeOnce.deliver(remoteCloseError, to: onClose)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        // We treat both stdout (.channel) and stderr (.stdErr) as terminal
        // output; a PTY shell normally merges them anyway.
        onOutput(buf)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        remoteCloseError = error
        deliverReady(.failure(error))
        closeOnce.deliver(error, to: onClose)
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent where onReady != nil:
            acknowledgedRequests += 1
            if acknowledgedRequests == 2 { deliverReady(.success(())) }
        case is ChannelFailureEvent where onReady != nil:
            let error = SSHExecError.requestRejected
            remoteCloseError = error
            deliverReady(.failure(error))
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            guard status.exitStatus != 0 else { return }
            let error = SSHExecError.nonZeroExitStatus(status: status.exitStatus, stderr: "")
            remoteCloseError = error
            deliverReady(.failure(error))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            let error = SSHExecError.remoteSignal(name: signal.signalName, message: signal.errorMessage)
            remoteCloseError = error
            deliverReady(.failure(error))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    /// Write outbound bytes to the server as channel data.
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        context.write(wrapOutboundOut(channelData), promise: promise)
    }

    /// Send a window-change request reflecting a new terminal size. Call on the
    /// channel's event loop.
    func sendWindowChange(cols: Int, rows: Int) {
        guard let context else { return }
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: self.cols,
            terminalRowHeight: self.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        context.triggerUserOutboundEvent(event, promise: nil)
    }

    private var acknowledgedRequests = 0

    private func deliverReady(_ result: Result<Void, Error>) {
        guard let onReady else { return }
        self.onReady = nil
        onReady(result)
    }
}
