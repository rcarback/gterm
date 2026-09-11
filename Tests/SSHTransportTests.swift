import XCTest
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

/// Real encrypted SSH handshakes over a loopback socket, with nested SSH servers
/// standing in for targets reached via direct-tcpip. No external host or key needed.
final class SSHTransportTests: XCTestCase {
    private func result<T>(_ future: EventLoopFuture<T>) throws -> T {
        let done = expectation(description: "Future completed")
        var value: Result<T, Error>?
        future.whenComplete { value = $0; done.fulfill() }
        wait(for: [done], timeout: 15)
        return try XCTUnwrap(value).get()
    }

    func testDirectAndTwoJumpConnectionsCarryData() throws {
        for hops in [0, 2] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try! group.syncShutdownGracefully() }
            let fixture = JumpServer(hops: hops)
            let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandler(fixture.handler(channel, index: 0))
            }.bind(host: "127.0.0.1", port: 0).wait()
            defer { try! server.close().wait() }
            var trusted: [String] = []
            let transport = SSHTransport(group: group) { prompt, decide in
                trusted.append(prompt.host)
                decide(true)
            }
            defer { try! transport.close().wait() }
            let endpoints = fixture.endpoints(port: server.localAddress!.port!)
            var target = endpoints.last!
            target.jumpHosts = Array(endpoints.dropLast())
            let channel = try result(transport.connect(target))
            XCTAssertEqual(trusted, endpoints.map { "\($0.host):\($0.port)" })
            XCTAssertEqual(fixture.targets, endpoints.dropFirst().map { "\($0.host):\($0.port)" })
            let received = group.next().makePromise(of: String.self)
            let shell = try result(channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let opened = channel.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(opened, channelType: .session) { child, _ in
                    child.pipeline.addHandler(ReceiveText(received))
                }
                return opened.futureResult
            })
            var buffer = shell.allocator.buffer(capacity: 5)
            buffer.writeString("hello")
            try shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).wait()
            XCTAssertEqual(try result(received.futureResult), "hello")
            try result(transport.close())
            XCTAssertFalse(channel.isActive)
        }
    }

    func testDestinationAuthenticationFailureClosesRoute() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }
        let fixture = JumpServer(hops: 1)
        let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(fixture.handler(channel, index: 0))
        }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try! server.close().wait() }
        let transport = SSHTransport(group: group) { _, decide in decide(true) }
        defer { try! transport.close().wait() }
        let endpoints = fixture.endpoints(port: server.localAddress!.port!)
        var target = endpoints.last!
        target.password = "wrong"
        target.jumpHosts = [endpoints[0]]
        XCTAssertThrowsError(try result(transport.connect(target)))
        try result(transport.close())
    }

    func testRefusedForwardFailsAndTransportCannotReconnectAfterClose() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }
        let fixture = JumpServer(hops: 0) // accepts sessions but refuses direct-tcpip
        let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(fixture.handler(channel, index: 0))
        }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try! server.close().wait() }
        let transport = SSHTransport(group: group) { _, decide in decide(true) }
        defer { try! transport.close().wait() }
        var target = SSHConnection(host: "unreachable.invalid", username: "destination", password: "secret")
        target.jumpHosts = fixture.endpoints(port: server.localAddress!.port!)
        XCTAssertThrowsError(try result(transport.connect(target)))
        try result(transport.close())
        XCTAssertThrowsError(try result(transport.connect(target)))
    }

    func testRejectDestinationHostKeyAndCancelDuringTrust() throws {
        for cancel in [false, true] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { try! group.syncShutdownGracefully() }
            let fixture = JumpServer(hops: 1)
            let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandler(fixture.handler(channel, index: 0))
            }.bind(host: "127.0.0.1", port: 0).wait()
            defer { try! server.close().wait() }
            var transport: SSHTransport!
            transport = SSHTransport(group: group) { prompt, decide in
                if prompt.host.hasPrefix("target-") {
                    if cancel { _ = transport.close() }
                    decide(false)
                } else { decide(true) }
            }
            defer { try! transport.close().wait() }
            let endpoints = fixture.endpoints(port: server.localAddress!.port!)
            var target = endpoints.last!
            target.jumpHosts = [endpoints[0]]
            XCTAssertThrowsError(try result(transport.connect(target)))
        }
    }
}

private final class JumpServer {
    let hops: Int
    let suffix = UUID().uuidString
    let keys: [NIOSSHPrivateKey]
    var targets: [String] = []

    init(hops: Int) {
        self.hops = hops
        keys = (0...hops).map { _ in NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()) }
    }

    func endpoints(port: Int) -> [SSHConnection] {
        (0...hops).map { index in
            SSHConnection(host: index == 0 ? "127.0.0.1" : "target-\(index)-\(suffix).invalid",
                          port: index == 0 ? port : 2200 + index,
                          username: "user\(index)", password: "password\(index)")
        }
    }

    func handler(_ channel: Channel, index: Int) -> NIOSSHHandler {
        NIOSSHHandler(role: .server(.init(
            hostKeys: [keys[index]], userAuthDelegate: ServerPassword(index: index)
        )), allocator: channel.allocator) { child, type in
            if index < self.hops {
                guard case .directTCPIP(let target) = type else {
                    return child.eventLoop.makeFailedFuture(TestError.unexpectedChannel)
                }
                self.targets.append("\(target.targetHost):\(target.targetPort)")
                return child.pipeline.addHandlers(SSHWrapperHandler(), self.handler(child, index: index + 1))
            }
            guard case .session = type else { return child.eventLoop.makeFailedFuture(TestError.unexpectedChannel) }
            return child.pipeline.addHandler(EchoText())
        }
    }
}

private enum TestError: Error { case unexpectedChannel }

private final class ServerPassword: NIOSSHServerUserAuthenticationDelegate {
    let index: Int
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
    init(index: Int) { self.index = index }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if request.username == "user\(index)", case .password(let password) = request.request,
           password.password == "password\(index)" {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}

private final class EchoText: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(wrapOutboundOut(unwrapInboundIn(data)), promise: nil)
    }
}

private final class ReceiveText: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let received: EventLoopPromise<String>
    private var completed = false
    init(_ received: EventLoopPromise<String>) { self.received = received }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed, case .byteBuffer(var buffer) = unwrapInboundIn(data).data else { return }
        completed = true
        received.succeed(buffer.readString(length: buffer.readableBytes) ?? "")
    }
}
