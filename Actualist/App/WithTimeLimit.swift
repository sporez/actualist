import Foundation

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
