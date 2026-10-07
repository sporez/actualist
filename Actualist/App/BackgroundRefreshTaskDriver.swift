import BackgroundTasks
import Synchronization

/// The slice of `BGAppRefreshTask` the expiration/completion logic needs.
/// `BGAppRefreshTask` cannot be constructed in tests, so tests drive a fake.
protocol BackgroundRefreshTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundRefreshTaskHandle {}

/// Completes a background task at most once, from whichever path gets there
/// first: the refresh finishing, the expiration grace timer, or a deadline.
///
/// Invariant: the wrapped task is not `Sendable`, but it is only touched by
/// `complete(success:)`, and the `Mutex`-guarded once flag lets exactly one
/// caller through, so concurrent or late callers never reach
/// `setTaskCompleted` twice. The system's `expirationHandler` assignment
/// happens once, in `BackgroundRefreshTaskDriver.drive`, on the delivery queue
/// before any completion path can run.
final class BackgroundRefreshTaskCompletion: @unchecked Sendable {
    private let task: any BackgroundRefreshTaskHandle
    private let completed = Mutex(false)

    init(task: any BackgroundRefreshTaskHandle) {
        self.task = task
    }

    func complete(success: Bool) {
        let isFirst = completed.withLock { completed -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        if isFirst {
            task.setTaskCompleted(success: success)
        }
    }
}

enum BackgroundRefreshTaskDriver {
    /// Time between the system's expiration signal and the forced completion.
    /// A refresh step that ignores cancellation must not hold the task past
    /// the system deadline, so expiration cancels the refresh and then reports
    /// failure after this grace period if the refresh has not unwound.
    static let expirationGrace: Duration = .seconds(2)

    /// Runs `refresh` for `task`. The returned task finishes once the refresh
    /// has returned and its completion path has run.
    @discardableResult
    static func drive(
        task: some BackgroundRefreshTaskHandle,
        expirationGrace: Duration = expirationGrace,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        refresh: @escaping @Sendable () async -> Bool
    ) -> Task<Void, Never> {
        let completion = BackgroundRefreshTaskCompletion(task: task)
        let refreshTask = Task { await refresh() }
        task.expirationHandler = {
            refreshTask.cancel()
            Task {
                do {
                    try await sleep(expirationGrace)
                } catch {
                    return
                }
                completion.complete(success: false)
            }
        }
        return Task {
            let success = await refreshTask.value
            completion.complete(success: success)
        }
    }
}
