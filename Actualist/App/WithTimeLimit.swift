import Foundation
import Synchronization

/// Runs an operation against a wall-clock limit: the first of the operation
/// finishing or the timeout wins. Shared by the background refresh runner
/// and the Phase 6 background bank-sync step. `timeoutError` lets each
/// caller keep its own error vocabulary.
func withTimeLimit<Result: Sendable>(
    _ timeLimit: Duration,
    timeoutError: some Error,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @MainActor @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await sleep(timeLimit)
            throw timeoutError
        }
        guard let result = try await group.next() else {
            throw timeoutError
        }
        group.cancelAll()
        return result
    }
}

/// Like `withTimeLimit`, but returns to the caller at the deadline even when
/// the operation ignores cancellation. A task group cannot return before its
/// operation child finishes, so a background caller racing a system deadline
/// uses this variant instead. The operation runs in an owned unstructured
/// task joined through a continuation that the operation's result, the
/// deadline, or caller cancellation resumes exactly once; the loser is
/// cancelled. A non-cooperative straggler keeps running only until it
/// observes cancellation, and callers rely on their session/identity guards
/// to keep it from publishing.
func withDeadline<Value: Sendable>(
    _ limit: Duration,
    timeoutError: some Error,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    let gate = DeadlineGate<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            let work = Task { @MainActor in
                do {
                    gate.finish(.success(try await operation()))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            let timer = Task {
                do {
                    try await sleep(limit)
                } catch is CancellationError {
                    return
                } catch {
                    // A failing sleep ends the wait with its own error, as in
                    // `withTimeLimit`.
                    gate.finish(.failure(error))
                    return
                }
                gate.finish(.failure(timeoutError))
            }
            gate.attach(work: work, timer: timer)
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// Resumes the deadline continuation once and cancels both child tasks.
/// Every entry point tolerates running before or after the others, because
/// cancellation and a fast operation can race installation.
private final class DeadlineGate<Value: Sendable>: Sendable {
    private struct State {
        var finished = false
        var pending: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let pending = state.withLock { state -> Result<Value, any Error>? in
            if let pending = state.pending { return pending }
            state.continuation = continuation
            return nil
        }
        if let pending {
            continuation.resume(with: pending)
        }
    }

    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let alreadyFinished = state.withLock { state -> Bool in
            if state.finished { return true }
            state.work = work
            state.timer = timer
            return false
        }
        if alreadyFinished {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        let winner = state.withLock { state -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !state.finished else { return nil }
            state.finished = true
            let continuation = state.continuation
            if continuation == nil { state.pending = result }
            defer {
                state.continuation = nil
                state.work = nil
                state.timer = nil
            }
            return (continuation, state.work, state.timer)
        }
        guard let (continuation, work, timer) = winner else { return }
        work?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
