import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Owns the outer TCP connection and nested SSH channels. All mutable state is
/// confined to one event loop, including cancellation during authentication.
final class SSHTransport {
    private let loop: EventLoop
    private let onHostKeyPrompt: TOFUHostKeyDelegate.Prompt?
    private var channels: [Channel] = []
    private var stopped = false
    private var closing: EventLoopFuture<Void>?

    init(group: EventLoopGroup, onHostKeyPrompt: TOFUHostKeyDelegate.Prompt?) {
        self.loop = group.next()
        self.onHostKeyPrompt = onHostKeyPrompt
    }

    func connect(_ connection: SSHConnection) -> EventLoopFuture<Channel> {
        loop.flatSubmit {
            let route = connection.jumpHosts + [connection]
            return self.connectTCP(route[0]).flatMap { first in
                var result = self.loop.makeSucceededFuture(first)
                for endpoint in route.dropFirst() {
                    result = result.flatMap { self.connectTunnel(to: endpoint, through: $0) }
                }
                return result
            }.flatMapError { error in
                self.close().flatMapThrowing { throw error }
            }
        }
    }

    func close() -> EventLoopFuture<Void> {
        loop.flatSubmit {
            if let closing = self.closing { return closing }
            self.stopped = true
            let completed = self.loop.makePromise(of: Void.self)
            self.closing = completed.futureResult
            let channels = self.channels.reversed()
            self.channels.removeAll()
            let closes = channels.map { $0.close().recover { _ in () } }
            EventLoopFuture.andAllComplete(closes, on: self.loop).cascade(to: completed)
            return completed.futureResult
        }
    }

    private func track(_ channel: Channel) throws {
        guard !stopped else {
            channel.close(promise: nil)
            throw SSHTransportError.cancelled
        }
        channels.append(channel)
    }

    private func connectTCP(_ endpoint: SSHConnection) -> EventLoopFuture<Channel> {
        guard !stopped else { return loop.makeFailedFuture(SSHTransportError.cancelled) }
        var authenticated: EventLoopFuture<Void>?
        return ClientBootstrap(group: loop)
            .connectTimeout(.seconds(20))
            .channelInitializer { channel in
                do {
                    try self.track(channel)
                    let ready = self.loop.makePromise(of: Void.self)
                    authenticated = ready.futureResult
                    return self.configure(channel, endpoint: endpoint, ready: ready)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: endpoint.host, port: endpoint.port)
            .flatMap { channel in authenticated!.map { channel } }
    }

    private func connectTunnel(to endpoint: SSHConnection, through parent: Channel) -> EventLoopFuture<Channel> {
        guard !stopped else { return loop.makeFailedFuture(SSHTransportError.cancelled) }
        var authenticated: EventLoopFuture<Void>?
        return parent.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
            let opened = self.loop.makePromise(of: Channel.self)
            // The destination name is sent verbatim to the jump server; no local
            // DNS lookup or listening TCP port is needed for the tunnel.
            let direct = SSHChannelType.DirectTCPIP(
                targetHost: endpoint.host, targetPort: endpoint.port,
                originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
            )
            ssh.createChannel(opened, channelType: .directTCPIP(direct)) { child, _ in
                do {
                    try self.track(child)
                    let ready = self.loop.makePromise(of: Void.self)
                    authenticated = ready.futureResult
                    return child.pipeline.addHandler(SSHWrapperHandler()).flatMap {
                        self.configure(child, endpoint: endpoint, ready: ready)
                    }
                } catch {
                    return self.loop.makeFailedFuture(error)
                }
            }
            return opened.futureResult.flatMap { child in authenticated!.map { child } }
        }
    }

    private func configure(_ channel: Channel, endpoint: SSHConnection,
                           ready: EventLoopPromise<Void>) -> EventLoopFuture<Void> {
        let parsed = SSHKeyParser.parseUsable(endpoint.privateKeys)
        var offers = parsed.keys.map { NIOSSHUserAuthenticationOffer.Offer.privateKey(.init(privateKey: $0.key)) }
        if !endpoint.password.isEmpty { offers.append(.password(.init(password: endpoint.password))) }
        guard !offers.isEmpty else {
            let error = SSHTransportError.endpoint(endpoint.host, parsed.firstError.map { String(describing: $0) } ?? "No usable key or password provided.")
            ready.fail(error)
            return loop.makeFailedFuture(error)
        }
        let ssh = NIOSSHHandler(
            role: .client(.init(
                userAuthDelegate: OrderedAuthDelegate(host: endpoint.host, username: endpoint.username, offers: offers),
                serverAuthDelegate: TOFUHostKeyDelegate(hostID: "\(endpoint.host):\(endpoint.port)", prompt: onHostKeyPrompt)
            )),
            allocator: channel.allocator, inboundChildChannelInitializer: nil
        )
        return channel.pipeline.addHandlers(ssh, SSHAuthenticationHandler(host: endpoint.host, ready: ready))
    }
}

enum SSHTransportError: LocalizedError {
    case cancelled
    case endpoint(String, String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Connection cancelled."
        case .endpoint(let host, let reason): return "\(host): \(reason)"
        }
    }
}

/// Wait for authentication at every hop before opening the next tunnel. Also
/// closes failed transports so nested handshake failures cannot leave sockets
/// or pending connection futures alive indefinitely.
final class SSHAuthenticationHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let host: String
    private var ready: EventLoopPromise<Void>?
    private var timeout: Scheduled<Void>?

    init(host: String, ready: EventLoopPromise<Void>) {
        self.host = host
        self.ready = ready
    }

    func handlerAdded(context: ChannelHandlerContext) {
        timeout = context.eventLoop.scheduleTask(in: .seconds(120)) {
            self.fail(SSHTransportError.endpoint(self.host, "SSH authentication timed out."), context: context)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            timeout?.cancel()
            timeout = nil
            let promise = ready
            ready = nil
            promise?.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SSHTransportError.endpoint(host, "SSH connection closed."), context: context)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timeout?.cancel()
        timeout = nil
        let promise = ready
        ready = nil
        promise?.fail(SSHTransportError.cancelled)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        timeout?.cancel()
        timeout = nil
        let promise = ready
        ready = nil
        promise?.fail(error)
        context.close(promise: nil)
    }
}
