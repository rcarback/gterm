import Foundation
import NIOCore
import NIOSSH

/// Errors raised by the keepalive timer itself.
enum SSHKeepaliveError: Error, LocalizedError {
    /// The parent channel was already inactive when a keepalive came due.
    case notConnected

    /// Enough consecutive probes went unanswered to call the connection gone.
    case unanswered

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .unanswered: return "Connection stopped responding."
        }
    }
}

/// Probes an authenticated SSH connection at a fixed interval and reports the
/// connection dead once too many probes go unanswered.
///
/// The probe is a global request asking to cancel a TCP forwarding that was
/// never established, so every server refuses it. A refusal is still a complete
/// round-trip through the encrypted transport, which is all the timer needs, so
/// this type counts a refusal as proof of life. Only silence counts as a miss.
///
/// Using `cancel-tcpip-forward` keeps the timer on the public swift-nio-ssh API.
/// The request name OpenSSH uses for this purpose, `keepalive@openssh.com`, is
/// not reachable without patching the library.
///
/// Every method is safe to call from any thread. All work hops to the parent
/// channel's event loop, because `sendTCPForwardingRequest` is not thread-safe.
final class SSHKeepalive {
    /// A host that can never name a real forwarding. `.invalid` is reserved by
    /// RFC 2606 precisely so it resolves nowhere, which keeps the probe from
    /// cancelling a binding that some other part of the app set up.
    static let probeHost = "gterm-keepalive.invalid"
    static let probePort = 0

    private let channel: Channel
    private let interval: TimeAmount
    private let onDead: () -> Void
    private var tracker: KeepaliveTracker
    private var task: RepeatedTask?
    private var reportedDead = false
    private var stopped = false

    init(
        channel: Channel,
        interval: TimeAmount = .seconds(Int64(KeepaliveTracker.defaultInterval)),
        missLimit: Int = KeepaliveTracker.defaultMissLimit,
        onDead: @escaping () -> Void
    ) {
        self.channel = channel
        self.interval = interval
        self.tracker = KeepaliveTracker(missLimit: missLimit)
        self.onDead = onDead
    }

    /// Begin the timer. Calling this twice starts one timer, and calling it
    /// after `stop()` starts none.
    func start() {
        channel.eventLoop.execute {
            guard self.task == nil, !self.stopped else { return }
            self.task = self.channel.eventLoop.scheduleRepeatedTask(
                initialDelay: self.interval,
                delay: self.interval
            ) { [weak self] _ in
                self?.tick()
            }
        }
    }

    /// Stop the timer. Safe to call when no timer is running, and safe to call
    /// more than once.
    func stop() {
        channel.eventLoop.execute {
            self.stopped = true
            self.task?.cancel()
            self.task = nil
        }
    }

    /// Fire one scheduled probe and fold the answer into the tracker.
    private func tick() {
        tracker.recordSent()
        if tracker.isConnectionDead {
            reportDeadOnce()
            return
        }
        send().whenComplete { [weak self] result in
            guard let self else { return }
            if case .success = result { self.tracker.recordReply() }
        }
    }

    /// Send one probe. Must run on the channel's event loop.
    private func send() -> EventLoopFuture<Void> {
        guard channel.isActive else {
            return channel.eventLoop.makeFailedFuture(SSHKeepaliveError.notConnected)
        }
        let reply = channel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { lookup in
            switch lookup {
            case .failure(let error):
                reply.fail(error)
            case .success(let handler):
                handler.sendTCPForwardingRequest(
                    .cancel(host: Self.probeHost, port: Self.probePort),
                    promise: reply
                )
            }
        }
        return reply.futureResult.map { _ in () }.flatMapError { error in
            // A refusal is the answer every server gives to this request, and it
            // proves the connection round-trips. Anything else is a real failure.
            if let sshError = error as? NIOSSHError, sshError.type == .globalRequestRefused {
                return self.channel.eventLoop.makeSucceededVoidFuture()
            }
            return self.channel.eventLoop.makeFailedFuture(error)
        }
    }

    private func reportDeadOnce() {
        guard !reportedDead else { return }
        reportedDead = true
        stopped = true
        task?.cancel()
        task = nil
        onDead()
    }
}
