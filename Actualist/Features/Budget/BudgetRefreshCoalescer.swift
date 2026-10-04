import Foundation

/// Joins overlapping refresh requests for the same budget onto one in-flight
/// load, so a burst of view-level refresh triggers flips `isLoading` once.
@MainActor
final class BudgetRefreshCoalescer {
    private struct InFlight {
        let id: Int
        let budgetID: String?
        let task: Task<Void, Never>
    }

    private var inFlight: InFlight?
    private var nextID = 0

    /// Runs `work`, or waits for the load already running for `budgetID`.
    /// A different budget starts its own load; the older one is superseded by
    /// the model's own load generation.
    func run(budgetID: String?, _ work: @escaping @MainActor () async -> Void) async {
        if let inFlight, inFlight.budgetID == budgetID {
            await inFlight.task.value
            return
        }
        nextID += 1
        let id = nextID
        let task = Task { @MainActor [weak self] in
            await work()
            if self?.inFlight?.id == id { self?.inFlight = nil }
        }
        inFlight = InFlight(id: id, budgetID: budgetID, task: task)
        await task.value
    }
}
