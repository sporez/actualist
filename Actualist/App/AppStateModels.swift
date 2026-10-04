enum SetupPhase: Equatable {
    case needsConnection
    case selectingBudget
    case restoringBudget
    case credentialUnavailable
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

/// Result of opening or reimporting a budget, so callers branch on the type
/// instead of comparing `lastErrorMessage` against localized error text.
enum BudgetOpenOutcome: Equatable {
    case opened
    case needsEncryptionPassword
    /// `message` is nil when the failure was a user/system cancellation.
    case failed(message: String?)
    case superseded
}

enum AppBudgetList {
    static func unique(_ budgets: [ActualBudget]) -> [ActualBudget] {
        var seenSyncIDs: Set<String> = []
        return budgets.filter { budget in
            seenSyncIDs.insert(budget.syncID).inserted
        }
    }
}
