import Foundation

/// Joins overlapping refresh requests for the same budget onto one in-flight
/// load, so a burst of view-level refresh triggers flips `isLoading` once.
/// A request that arrives after that load's read began may follow a newer
/// commit the read missed, so it schedules exactly one trailing re-run.
@MainActor
final class BudgetRefreshCoalescer {
    private struct InFlight {
        let id: Int
        let budgetID: String?
        let task: Task<Void, Never>
        var needsTrailingRun = false
    }

    private var inFlight: InFlight?
    private var nextID = 0

    /// Runs `work`, or waits for the load already running for `budgetID` and the
    /// single trailing run its late requests share.
    /// A different budget starts its own load; the older one is superseded by
    /// the model's own load generation.
    func run(budgetID: String?, _ work: @escaping @MainActor () async -> Void) async {
        if let inFlight, inFlight.budgetID == budgetID {
            self.inFlight?.needsTrailingRun = true
            await inFlight.task.value
            return
        }
        nextID += 1
        let id = nextID
        let task = Task { @MainActor [weak self] in
            await work()
            while self?.inFlight?.id == id, self?.inFlight?.needsTrailingRun == true {
                self?.inFlight?.needsTrailingRun = false
                await work()
            }
            if self?.inFlight?.id == id { self?.inFlight = nil }
        }
        inFlight = InFlight(id: id, budgetID: budgetID, task: task)
        await task.value
    }
}
