import Foundation

/// Shares one foreground health check between the host list and terminal views.
@MainActor
final class SessionRecovery {
    private let check: () async throws -> Void
    private let reconnect: () async -> Void
    private var needsCheck = false
    private var task: Task<Void, Never>?
    private var generation = 0
    var isPending: Bool { needsCheck || task != nil }

    init(check: @escaping () async throws -> Void, reconnect: @escaping () async -> Void) {
        self.check = check
        self.reconnect = reconnect
    }

    func enteredBackground() { needsCheck = true }

    func resume() async {
        if let task { await task.value; return }
        guard needsCheck else { return }
        needsCheck = false
        let token = generation
        let task = Task {
            defer { if generation == token { self.task = nil } }
            do { try await check() }
            catch {
                guard !Task.isCancelled else { return }
                await reconnect()
            }
        }
        self.task = task
        await task.value
    }

    func cancel() {
        generation += 1
        needsCheck = false
        task?.cancel()
        task = nil
    }
}
