import XCTest
import Crypto
import NIOCore
import NIOEmbedded
import NIOSSH

final class SSHExecHandlerTests: XCTestCase {
    func testSuccessfulCommandReturnsStandardOutputAfterAcknowledgementAndExit() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        try channel.writeInbound(data("window-list\n", type: .channel))
        try channel.writeInbound(data("ignored warning", type: .stdErr))
        channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
        try channel.writeInbound(data("tail", type: .channel))
        XCTAssertTrue(results.isEmpty)
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        channel.embeddedEventLoop.run()

        XCTAssertEqual(try XCTUnwrap(results.first).get(), "window-list\ntail")
        XCTAssertEqual(results.count, 1)
    }

    func testNonzeroExitReportsStandardError() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 1))
        try channel.writeInbound(data("screen: no session", type: .stdErr))
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        guard case .failure(let error) = try XCTUnwrap(results.first),
              let execError = error as? SSHExecError,
              case .nonZeroExitStatus(let status, let stderr) = execError else {
            return XCTFail("Expected a nonzero-exit error")
        }
        XCTAssertEqual(status, 1)
        XCTAssertEqual(stderr, "screen: no session")
    }

    func testNonzeroExitUsesStandardOutputWhenStandardErrorIsEmpty() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        try channel.writeInbound(data("No Sockets found.\n", type: .channel))
        channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 1))
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        guard case .failure(let error) = try XCTUnwrap(results.first),
              let execError = error as? SSHExecError,
              case .nonZeroExitStatus(_, let diagnostic) = execError else {
            return XCTFail("Expected a nonzero-exit error")
        }
        XCTAssertEqual(diagnostic, "No Sockets found.\n")
    }

    func testExitStatusAfterEOFCompletesWithoutWaitingForChannelClose() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        try channel.writeInbound(data("complete", type: .channel))
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertTrue(results.isEmpty)
        channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
        channel.embeddedEventLoop.run()

        XCTAssertEqual(try XCTUnwrap(results.first).get(), "complete")
        XCTAssertEqual(results.count, 1)
    }

    func testOperationSendsCommandAfterConnectionActivates() throws {
        let harness = try ExecOperationHarness()
        defer { XCTAssertNoThrow(try harness.finish()) }
        let operation = SSHExecOperation(
            parentChannel: harness.client,
            command: "screen -ls",
            timeout: .seconds(10)
        )
        operation.start()
        harness.run()
        try harness.activateAndExchange()
        XCTAssertEqual(harness.commandRequests, 1)
        XCTAssertEqual(harness.openedChildChannels, 1)
        operation.cancel()
        harness.run()
    }

    func testOperationTimeoutPreventsLateCommandRequest() throws {
        let harness = try ExecOperationHarness()
        defer { XCTAssertNoThrow(try harness.finish()) }
        let operation = SSHExecOperation(
            parentChannel: harness.client,
            command: "screen -ls",
            timeout: .milliseconds(1)
        )
        var result: Result<String, Error>?
        operation.result.whenComplete { result = $0 }

        operation.start()
        harness.run()
        harness.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(execError(from: result), .timedOut)

        try harness.activateAndExchange()
        XCTAssertEqual(harness.commandRequests, 0)
        XCTAssertEqual(harness.openedChildChannels, 0)
    }

    func testOperationCancellationPreventsLateCommandRequest() throws {
        let harness = try ExecOperationHarness()
        defer { XCTAssertNoThrow(try harness.finish()) }
        let operation = SSHExecOperation(
            parentChannel: harness.client,
            command: "screen -ls",
            timeout: .seconds(10)
        )
        var result: Result<String, Error>?
        operation.result.whenComplete { result = $0 }

        operation.start()
        harness.run()
        operation.cancel()
        harness.run()
        XCTAssertEqual(execError(from: result), .cancelled)

        try harness.activateAndExchange()
        XCTAssertEqual(harness.commandRequests, 0)
        XCTAssertEqual(harness.openedChildChannels, 0)
    }

    func testRequestRejectionCompletesOnce() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelFailureEvent())
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        guard case .failure(let error) = try XCTUnwrap(results.first) else {
            return XCTFail("Expected request rejection")
        }
        XCTAssertEqual(error as? SSHExecError, .requestRejected)
        XCTAssertEqual(results.count, 1)
    }

    func testCloseAfterAcknowledgementWithoutExitStatusFails() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        guard case .failure(let error) = try XCTUnwrap(results.first) else {
            return XCTFail("Expected a missing-exit-status error")
        }
        XCTAssertEqual(error as? SSHExecError, .missingExitStatus)
    }

    func testCloseBeforeAcknowledgementReportsDisconnect() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel { results.append($0) }

        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        guard case .failure(let error) = try XCTUnwrap(results.first) else {
            return XCTFail("Expected a disconnect error")
        }
        XCTAssertEqual(error as? SSHExecError, .disconnected)
    }

    func testCombinedOutputLimitIncludesStandardError() throws {
        var results: [Result<String, Error>] = []
        let channel = try makeChannel(maximumOutputBytes: 4) { results.append($0) }

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        try channel.writeInbound(data("abc", type: .channel))
        try channel.writeInbound(data("de", type: .stdErr))
        channel.embeddedEventLoop.run()

        guard case .failure(let error) = try XCTUnwrap(results.first),
              let execError = error as? SSHExecError,
              case .outputLimitExceeded(let limit) = execError else {
            return XCTFail("Expected an output-limit error")
        }
        XCTAssertEqual(limit, 4)
    }

    func testPTYCommandRequiresBothRequestAcknowledgements() throws {
        var ready: [Result<Void, Error>] = []
        let handler = PTYChannelHandler(
            term: "xterm-256color",
            cols: 80,
            rows: 24,
            command: "screen -x session",
            onOutput: { _ in },
            onReady: { ready.append($0) },
            onClose: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        XCTAssertTrue(ready.isEmpty)
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.embeddedEventLoop.run()

        XCTAssertNoThrow(try XCTUnwrap(ready.first).get())
        XCTAssertEqual(ready.count, 1)
        XCTAssertNoThrow(try channel.finish())
    }

    func testPTYNonzeroExitReachesCloseCallback() throws {
        var closeError: SSHExecError?
        var closeCount = 0
        let handler = PTYChannelHandler(
            term: "xterm-256color",
            cols: 80,
            rows: 24,
            command: "screen -x missing",
            onOutput: { _ in },
            onReady: { _ in },
            onClose: {
                closeError = $0 as? SSHExecError
                closeCount += 1
            }
        )
        let channel = EmbeddedChannel(handler: handler)

        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 1))
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        XCTAssertEqual(closeError, .nonZeroExitStatus(status: 1, stderr: ""))
        XCTAssertEqual(closeCount, 1)
        XCTAssertNoThrow(try channel.finish())
    }

    private func makeChannel(
        maximumOutputBytes: Int = 256 * 1024,
        completion: @escaping (Result<String, Error>) -> Void
    ) throws -> EmbeddedChannel {
        let handler = SSHExecHandler(
            command: "screen -ls",
            maximumOutputBytes: maximumOutputBytes,
            completion: completion
        )
        return EmbeddedChannel(handler: handler)
    }

    private func data(_ text: String, type: SSHChannelData.DataType) -> SSHChannelData {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return SSHChannelData(type: type, data: .byteBuffer(buffer))
    }

    private func execError(from result: Result<String, Error>?) -> SSHExecError? {
        guard let result, case .failure(let error) = result else { return nil }
        return error as? SSHExecError
    }
}

private final class ExecOperationHarness {
    private let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    private let server: EmbeddedChannel
    private(set) var commandRequests = 0
    private(set) var openedChildChannels = 0

    init() throws {
        client = EmbeddedChannel(loop: loop)
        server = EmbeddedChannel(loop: loop)
        let serverKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let clientHandler = NIOSSHHandler(
            role: .client(.init(
                userAuthDelegate: ExecClientAuthentication(),
                serverAuthDelegate: ExecHostKeyAcceptance()
            )),
            allocator: client.allocator,
            inboundChildChannelInitializer: nil
        )
        let serverHandler = NIOSSHHandler(
            role: .server(.init(
                hostKeys: [serverKey],
                userAuthDelegate: ExecServerAuthentication()
            )),
            allocator: server.allocator
        ) { child, _ in
            self.openedChildChannels += 1
            return child.pipeline.addHandler(ExecRequestCounter { self.commandRequests += 1 })
        }
        try client.pipeline.syncOperations.addHandler(clientHandler)
        try server.pipeline.syncOperations.addHandler(serverHandler)
    }

    func run() {
        loop.run()
    }

    func advanceTime(by amount: TimeAmount) {
        loop.advanceTime(by: amount)
    }

    func activateAndExchange() throws {
        try client.connect(to: .init(unixDomainSocketPath: "/client")).wait()
        try server.connect(to: .init(unixDomainSocketPath: "/server")).wait()
        var exchangedData = true
        while exchangedData {
            exchangedData = false
            loop.run()
            if let data = try client.readOutbound(as: IOData.self) {
                try server.writeInbound(data)
                exchangedData = true
            }
            if let data = try server.readOutbound(as: IOData.self) {
                try client.writeInbound(data)
                exchangedData = true
            }
        }
    }

    func finish() throws {
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try server.finish(acceptAlreadyClosed: true)
        try loop.syncShutdownGracefully()
    }
}

private final class ExecClientAuthentication: NIOSSHClientUserAuthenticationDelegate {
    private var offeredPassword = false

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password), !offeredPassword else {
            nextChallengePromise.succeed(nil)
            return
        }
        offeredPassword = true
        nextChallengePromise.succeed(.init(
            username: "exec-test",
            serviceName: "",
            offer: .password(.init(password: "password"))
        ))
    }
}

private struct ExecHostKeyAcceptance: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        validationCompletePromise.succeed(())
    }
}

private struct ExecServerAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        guard request.username == "exec-test",
              case .password(let password) = request.request,
              password.password == "password" else {
            responsePromise.succeed(.failure)
            return
        }
        responsePromise.succeed(.success)
    }
}

private final class ExecRequestCounter: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let onRequest: () -> Void

    init(onRequest: @escaping () -> Void) {
        self.onRequest = onRequest
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ExecRequest { onRequest() }
        context.fireUserInboundEventTriggered(event)
    }
}
