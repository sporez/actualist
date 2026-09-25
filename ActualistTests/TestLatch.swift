import Foundation
import Synchronization

/// Continuation-backed one-shot latch for test coordination. Waiters suspend
/// on a continuation instead of spinning `Task.yield()` loops: yield-spinning
/// keeps a task permanently runnable, so under Swift Testing's in-process
/// concurrency a handful of spinners dominate the cooperative executor queue
/// and starve every other test's actor hops (observed 2026-09-25: ~800 tests
/// slowed 100x, coordination tests hitting their 120s limits).
///
/// Tripping is broadcast: every current and future waiter proceeds after the
/// latch opens. A latch never re-closes; create one per coordination point.
/// Mutex-based (not actor-based) so fakes can trip it from synchronous
/// contexts such as `withCheckedContinuation` bodies.
final class TestLatch: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Suspends until `trip()` is called; returns immediately once tripped.
    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state -> Bool in
                guard !state.open else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    /// Opens the latch and resumes all waiters. Idempotent.
    func trip() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.open else { return [] }
            state.open = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
