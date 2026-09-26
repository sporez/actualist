import Foundation
import Synchronization

/// Continuation-backed one-shot latch for test coordination. Waiters suspend
/// on a continuation instead of spinning `Task.yield()` loops. Yield-spinning
/// keeps a task runnable and should not be reintroduced. Replacing those loops
/// did not remove the original full-suite time-limit fingerprint; later
/// samples showed synchronous system-Keychain waits, and two fixture defaults
/// plus internal serialization of `LocalFirstActualStoreTests` were the
/// accepted scheduling candidate. Do not treat this latch as proof of an
/// unbounded runner or of a universal test-count limit.
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
