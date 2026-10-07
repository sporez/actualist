import Foundation

/// The single server-sync lane for one budget session (concurrency 5.1, CA-15).
///
/// Flushes and pulls run strictly one at a time, in request order. The lane
/// owns what used to be loose store state: the flush-running flag, the
/// "flush again" request, the waiters, the scheduled-flush task handle, the
/// status-ordering tickets and the inserted-id accumulation of a background
/// run (D16, in memory only).
///
/// A session owns one lane; `closeOpenBudget()` invalidates it and installs a
/// fresh one, so an operation that finishes after a session change releases its
/// own (dead) lane and can never touch the new session's state.
@MainActor
final class ServerSyncLane {
    enum Operation: Equatable, Sendable {
        case flush
        case pull
    }

    enum State: Equatable, Sendable {
        case idle
        case running(Operation)
    }

    private struct Waiter {
        let id: UUID
        let operation: Operation
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var state: State = .idle
    private var waiters: [Waiter] = []
    private var isInvalidated = false
    private var ticketCounter = 0
    private var latestStatusTicket = 0
    private var backgroundRuns: [UUID: [String: Set<String>]] = [:]

    /// A write committed while a scheduled flush was past its serialized loop
    /// (or backing off) only sets this; the scheduled task consumes it for
    /// another pass (concurrency 0.5's tail re-check).
    var flushRequestedAgain = false
    /// The scheduled outbox-flush task, including its retry backoff.
    var scheduledFlushTask: Task<Void, Never>?

    #if DEBUG
    /// Test seam: fires when a request has queued behind the running operation.
    var onWaiterEnqueued: (@MainActor () -> Void)?
    #endif

    var isFlushing: Bool { state == .running(.flush) }
    var waiterCount: Int { waiters.count }

    /// Runs `body` as the lane's current operation, after every earlier request
    /// has finished. `body` receives this run's status ticket. A flush request
    /// that arrives while a flush runs asks that flush to take another pass.
    func run<T>(_ operation: Operation, body: (_ ticket: Int) async throws -> T) async throws -> T {
        if operation == .flush, isFlushing { flushRequestedAgain = true }
        try await acquire(operation)
        defer { release() }
        ticketCounter += 1
        return try await body(ticketCounter)
    }

    func takeFlushRequestedAgain() -> Bool {
        defer { flushRequestedAgain = false }
        return flushRequestedAgain
    }

    // MARK: Status ordering

    /// True when a status update from `ticket` may be applied: an update from
    /// an older operation than one already applied is dropped, so an older
    /// failure cannot overwrite a newer success.
    func acceptsStatus(ticket: Int) -> Bool {
        guard ticket >= latestStatusTicket else { return false }
        latestStatusTicket = ticket
        return true
    }

    /// A ticket for a status update recorded outside a lane operation, newer
    /// than every operation started so far.
    func nextTicket() -> Int {
        ticketCounter += 1
        return ticketCounter
    }

    // MARK: Background-run attribution (D16)

    func beginBackgroundRun() -> UUID {
        let token = UUID()
        backgroundRuns[token] = [:]
        return token
    }

    /// Every apply that lands while a background run is active counts toward
    /// that run: its own pull, a leftover upload retry and schedule-posting pulls.
    func noteInserted(_ idsByAccount: [String: [String]]) {
        guard !backgroundRuns.isEmpty, !idsByAccount.isEmpty else { return }
        for token in backgroundRuns.keys {
            for (accountID, ids) in idsByAccount {
                backgroundRuns[token, default: [:]][accountID, default: []].formUnion(ids)
            }
        }
    }

    func endBackgroundRun(_ token: UUID) -> [String: [String]] {
        (backgroundRuns.removeValue(forKey: token) ?? [:]).mapValues { $0.sorted() }
    }

    // MARK: Session end

    /// Ends the session: cancels the scheduled flush and every waiter.
    func invalidate() {
        isInvalidated = true
        scheduledFlushTask?.cancel()
        scheduledFlushTask = nil
        flushRequestedAgain = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
        backgroundRuns = [:]
    }

    // MARK: Queue

    private func acquire(_ operation: Operation) async throws {
        try Task.checkCancellation()
        if isInvalidated { throw CancellationError() }
        if state == .idle {
            state = .running(operation)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler(
            operation: { () async throws -> Void in
                try await self.enqueueWaiter(id: id, operation: operation)
            },
            onCancel: {
                Task { @MainActor in self.cancelWaiter(id: id) }
            }
        )
    }

    private func enqueueWaiter(id: UUID, operation: Operation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            waiters.append(Waiter(id: id, operation: operation, continuation: continuation))
            #if DEBUG
            onWaiterEnqueued?()
            #endif
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the lane directly to the next waiter, so no third caller can slip in.
    private func release() {
        guard !waiters.isEmpty else {
            state = .idle
            return
        }
        let next = waiters.removeFirst()
        state = .running(next.operation)
        next.continuation.resume()
    }
}
