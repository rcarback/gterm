import Foundation
import NIOCore
import NIOSSH

/// Sends `keepalive@openssh.com` on an authenticated SSH connection at a fixed
/// interval, and reports the connection dead once too many go unanswered.
///
/// Peers refuse the request, because no server implements that name. A refusal
/// is a complete round-trip, so this type counts it as a live connection. Only
/// silence counts as a miss.
///
/// Every method is safe to call from any thread. All work hops to the parent
/// channel's event loop, because `sendGlobalRequest` is not thread-safe.
final class SSHKeepalive {
    static let requestName = "keepalive@openssh.com"

    private let channel: Channel
    private let interval: TimeAmount
    private let onDead: () -> Void
    private var tracker: KeepaliveTracker
    private var task: RepeatedTask?
    private var reportedDead = false

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

    /// Begin the timer. Calling this twice starts one timer.
    func start() {
        channel.eventLoop.execute {
            guard self.task == nil else { return }
            self.task = self.channel.eventLoop.scheduleRepeatedTask(
                initialDelay: self.interval,
                delay: self.interval
            ) { [weak self] _ in
                self?.tick()
            }
        }
    }

    /// Stop the timer. Safe to call when no timer is running.
    func stop() {
        channel.eventLoop.execute {
            self.task?.cancel()
            self.task = nil
        }
    }

    /// One immediate round-trip, used as the liveness probe when the app returns
    /// to the foreground. Succeeds on any answer, including a refusal.
    func probe(timeout: TimeAmount = .seconds(3)) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.eventLoop.execute {
            let deadline = self.channel.eventLoop.scheduleTask(in: timeout) {
                promise.fail(SSHExecError.keepaliveTimedOut)
            }
            self.send().whenComplete { result in
                deadline.cancel()
                promise.completeWith(result)
            }
        }
        return promise.futureResult
    }

    /// Fire one scheduled keepalive and fold the answer into the tracker.
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

    /// Send one keepalive. Must run on the channel's event loop.
    private func send() -> EventLoopFuture<Void> {
        guard channel.isActive else {
            return channel.eventLoop.makeFailedFuture(SSHExecError.notConnected)
        }
        let reply = channel.eventLoop.makePromise(of: ByteBuffer?.self)
        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { lookup in
            switch lookup {
            case .failure(let error):
                reply.fail(error)
            case .success(let handler):
                handler.sendGlobalRequest(name: Self.requestName, promise: reply)
            }
        }
        return reply.futureResult.map { _ in () }.flatMapError { error in
            // A refusal is the answer every server gives, and it proves the
            // connection round-trips. Anything else is a real failure.
            if let sshError = error as? NIOSSHError, sshError.type == .globalRequestRefused {
                return self.channel.eventLoop.makeSucceededVoidFuture()
            }
            return self.channel.eventLoop.makeFailedFuture(error)
        }
    }

    private func reportDeadOnce() {
        guard !reportedDead else { return }
        reportedDead = true
        task?.cancel()
        task = nil
        onDead()
    }
}
