import XCTest
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

final class PostQuantumKeyExchangeTests: XCTestCase {
    func testDefaultConnectionNegotiatesHybridKeyExchangeAndAuthenticates() throws {
        let expected = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let unrelated = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let serverKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try! group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [serverKey], userAuthDelegate: AcceptGeneratedKey(key: expected.publicKey))),
                    allocator: channel.allocator, inboundChildChannelInitializer: nil))
            }
        }.bind(host: "127.0.0.1", port: 0).wait()
        defer { try! server.close().wait() }
        for (key, shouldPass) in [(expected, true), (unrelated, false)] {
            let ready = group.next().makePromise(of: Bool.self)
            let client = try ClientBootstrap(group: group).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: OfferGeneratedKey(key: key),
                                                          serverAuthDelegate: ExpectServerKey(key: serverKey.publicKey))),
                                      allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        AuthenticationResult(ready: ready)
                    ])
                }
            }.connect(host: "127.0.0.1", port: server.localAddress!.port!).wait()
            defer { try! client.close().wait() }
            let done = expectation(description: "Authentication completed")
            var actual: Bool?
            ready.futureResult.whenSuccess { actual = $0; done.fulfill() }
            wait(for: [done], timeout: 10)
            XCTAssertEqual(actual, shouldPass)
        }
    }
}

private enum AuthenticationTestError: Error { case rejected }
private final class AcceptGeneratedKey: NIOSSHServerUserAuthenticationDelegate {
    let key: NIOSSHPublicKey
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey
    init(key: NIOSSHPublicKey) { self.key = key }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if request.username == "test", case .publicKey(let offered) = request.request, offered.publicKey == key {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}
private final class OfferGeneratedKey: NIOSSHClientUserAuthenticationDelegate {
    let key: NIOSSHPrivateKey
    var offered = false
    init(key: NIOSSHPrivateKey) { self.key = key }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered else { nextChallengePromise.fail(AuthenticationTestError.rejected); return }
        offered = true
        nextChallengePromise.succeed(.init(username: "test", serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}
private final class ExpectServerKey: NIOSSHClientServerAuthenticationDelegate {
    let key: NIOSSHPublicKey
    init(key: NIOSSHPublicKey) { self.key = key }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if hostKey == key { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(AuthenticationTestError.rejected) }
    }
}
private final class AuthenticationResult: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var ready: EventLoopPromise<Bool>?
    var keyExchange: String?
    init(ready: EventLoopPromise<Bool>) { self.ready = ready }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exchange = event as? NIOSSHKeyExchangeCompletedEvent {
            keyExchange = exchange.keyExchangeAlgorithm
        }
        if event is UserAuthSuccessEvent {
            ready?.succeed(keyExchange == "mlkem768x25519-sha256"); ready = nil
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready?.succeed(false); ready = nil
        // The owner closes the channel after checking the result.
    }
}
