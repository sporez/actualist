enum SetupPhase: Equatable {
    case needsConnection
    case selectingBudget
    case restoringBudget
    case ready
}

enum ServerConnectionStatus: Equatable {
    case online
    case connecting
    case offline
    /// The server is reachable, but the open budget's sync was rejected for a
    /// budget-specific reason (for example its encryption changed on the
    /// server). Distinct from `.offline`, which means the server could not be
    /// reached at all.
    case syncBlocked
}

enum AppBudgetList {
    static func unique(_ budgets: [ActualBudget]) -> [ActualBudget] {
        var seenSyncIDs: Set<String> = []
        return budgets.filter { budget in
            seenSyncIDs.insert(budget.syncID).inserted
        }
    }
}
