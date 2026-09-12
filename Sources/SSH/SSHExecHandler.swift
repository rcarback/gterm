import Foundation
import NIOCore
import NIOSSH

enum SSHExecError: Error, Equatable, LocalizedError {
    case notConnected
    case channelOpenFailed(String)
    case requestRejected
    case disconnected
    case missingExitStatus
    case nonZeroExitStatus(status: Int, stderr: String)
    case remoteSignal(name: String, message: String)
    case outputLimitExceeded(limit: Int)
    case timedOut
    case keepaliveTimedOut
    case cancelled
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The SSH connection is not ready."
        case .channelOpenFailed(let message):
            return "Could not open an SSH command channel: \(message)"
        case .requestRejected:
            return "The SSH server rejected the command request."
        case .disconnected:
            return "The SSH command channel disconnected before the command started."
        case .missingExitStatus:
            return "The SSH command channel closed without an exit status."
        case .nonZeroExitStatus(let status, let stderr):
            let detail = stderr.isEmpty ? "No standard error output was returned." : stderr
            return "The SSH command exited with status \(status): \(detail)"
        case .remoteSignal(let name, let message):
            return message.isEmpty
                ? "The SSH command was stopped by signal \(name)."
                : "The SSH command was stopped by signal \(name): \(message)"
        case .outputLimitExceeded(let limit):
            return "The SSH command returned more than \(limit) bytes."
        case .timedOut:
            return "The SSH command timed out."
        case .keepaliveTimedOut:
            return "The SSH connection stopped responding."
        case .cancelled:
            return "The SSH command was cancelled."
        case .transportError(let message):
            return "The SSH command failed: \(message)"
        }
    }
}

/// Runs one command on an SSH session child channel and collects its output.
/// The owner supplies the overall timeout because channel creation occurs
/// before this handler is installed.
final class SSHExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let maximumOutputBytes: Int
    private var completion: ((Result<String, Error>) -> Void)?
    private var stdout: [UInt8] = []
    private var stderr: [UInt8] = []
    private var requestAccepted = false
    private var exitStatus: Int?
    private var exitSignal: SSHExecError?
    private var remoteEOFReceived = false

    init(
        command: String,
        maximumOutputBytes: Int = 256 * 1024,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        self.command = command
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.completion = completion
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = channelData.data else { return }
        guard channelData.type == .channel || channelData.type == .stdErr else { return }
        let count = buffer.readableBytes
        guard count <= maximumOutputBytes - stdout.count - stderr.count else {
            finish(.failure(SSHExecError.outputLimitExceeded(limit: maximumOutputBytes)), context: context)
            return
        }
        guard let bytes = buffer.readBytes(length: count) else { return }
        switch channelData.type {
        case .channel:
            stdout.append(contentsOf: bytes)
        case .stdErr:
            stderr.append(contentsOf: bytes)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            requestAccepted = true
        case is ChannelFailureEvent:
            finish(.failure(SSHExecError.requestRejected), context: context)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
            if remoteEOFReceived { completeAfterRemoteEOF(context: context) }
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitSignal = .remoteSignal(name: signal.signalName, message: signal.errorMessage)
            if remoteEOFReceived { completeAfterRemoteEOF(context: context) }
        case let event as ChannelEvent where event == .inputClosed:
            remoteEOFReceived = true
            if exitStatus != nil || exitSignal != nil {
                completeAfterRemoteEOF(context: context)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        completeAfterRemoteEOF(context: nil)
        context.fireChannelInactive()
    }

    private func completeAfterRemoteEOF(context: ChannelHandlerContext?) {
        if let exitSignal {
            finish(.failure(exitSignal), context: context)
        } else if requestAccepted, let exitStatus {
            if exitStatus == 0 {
                finish(.success(String(decoding: stdout, as: UTF8.self)), context: context)
            } else {
                let diagnostic = stderr.isEmpty ? stdout : stderr
                finish(.failure(SSHExecError.nonZeroExitStatus(
                    status: exitStatus,
                    stderr: String(decoding: diagnostic, as: UTF8.self)
                )), context: context)
            }
        } else {
            let error: SSHExecError = requestAccepted ? .missingExitStatus : .disconnected
            finish(.failure(error), context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(SSHExecError.transportError(error.localizedDescription)), context: context)
    }

    private func finish(_ result: Result<String, Error>, context: ChannelHandlerContext?) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
        context?.close(promise: nil)
    }
}

/// Owns the timeout and child-channel creation for one exec request.
final class SSHExecOperation {
    private let parentChannel: Channel
    private let command: String
    private let timeout: TimeAmount
    private let resultPromise: EventLoopPromise<String>
    private var childChannel: Channel?
    private var timeoutTask: Scheduled<Void>?
    private var completed = false

    init(parentChannel: Channel, command: String, timeout: TimeAmount) {
        self.parentChannel = parentChannel
        self.command = command
        self.timeout = timeout
        self.resultPromise = parentChannel.eventLoop.makePromise(of: String.self)
    }

    var result: EventLoopFuture<String> { resultPromise.futureResult }

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
                    guard !self.completed else { return }
                    let channelPromise = self.parentChannel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(channelPromise, channelType: .session) { child, _ in
                        guard !self.completed else {
                            child.close(promise: nil)
                            return child.eventLoop.makeFailedFuture(SSHExecError.cancelled)
                        }
                        return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                            child.pipeline.addHandler(SSHExecHandler(command: self.command) { result in
                                self.finish(result)
                            })
                        }
                    }
                    channelPromise.futureResult.whenComplete { opened in
                        switch opened {
                        case .failure(let error):
                            self.finish(.failure(SSHExecError.channelOpenFailed(error.localizedDescription)))
                        case .success(let child):
                            self.childChannel = child
                            if self.completed { child.close(promise: nil) }
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        finish(.failure(SSHExecError.cancelled))
    }

    private func finish(_ result: Result<String, Error>) {
        guard parentChannel.eventLoop.inEventLoop else {
            parentChannel.eventLoop.execute { self.finish(result) }
            return
        }
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure = result { childChannel?.close(promise: nil) }
        resultPromise.completeWith(result)
    }
}
