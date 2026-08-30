import Foundation

/// Execution seam for `BackgroundTransactionWorkflow`: the workflow composes
/// the refresh run, recording, notifications, and badge, while a conforming
/// type performs the actual sync. The production conformer is
/// `BackgroundTransactionRefreshRunner`; tests inject a fake to exercide the
/// `.synced`/`.skipped`/cancelled/timed-out/failed outcome paths without a
/// real budget sync.
@MainActor
protocol BackgroundTransactionRefreshing {
    func run(
        settings: AppSettings,
        selectedBudget: ActualBudget?,
        budgets: [ActualBudget],
        hasSyncCredentials: Bool,
        store: LocalFirstActualStore,
        timeLimit: Duration
    ) async throws -> BackgroundTransactionRefreshOutcome
}

enum BackgroundTransactionRefreshRunnerError: LocalizedError, Sendable {
    case timeLimitExceeded

    var errorDescription: String? {
        "Background refresh timed out before completion"
    }
}



struct BackgroundPendingTransactions: Sendable {
    let accountID: String
    let transactionIDs: [String]
}

struct BackgroundTransactionRefreshResult: Sendable {
    let budgetID: String
    let accountCount: Int
    let pendingTransactions: [BackgroundPendingTransactions]

    var newTransactionCount: Int {
        pendingTransactions.reduce(0) { $0 + $1.transactionIDs.count }
    }

    var completionMessage: String {
        guard newTransactionCount > 0 else {
            return "Synced budget; no new transactions"
        }

        let transactionNoun = newTransactionCount == 1 ? "transaction" : "transactions"
        let accountNoun = accountCount == 1 ? "account" : "accounts"
        return """
            Synced budget; found \(newTransactionCount) new \(transactionNoun) \
            across \(accountCount) \(accountNoun)
            """
    }
}

enum BackgroundTransactionRefreshOutcome: Sendable {
    case skipped(String)
    case synced(BackgroundTransactionRefreshResult)

    var message: String {
        switch self {
        case .skipped(let message):
            message
        case .synced(let result):
            result.completionMessage
        }
    }
}

@MainActor
struct BackgroundTransactionRefreshRunner: BackgroundTransactionRefreshing {
    func run(
        settings: AppSettings,
        selectedBudget: ActualBudget?,
        budgets: [ActualBudget],
        hasSyncCredentials: Bool,
        store: LocalFirstActualStore,
        timeLimit: Duration
    ) async throws -> BackgroundTransactionRefreshOutcome {
        // Background refresh may run before the foreground scene restores AppState.
        if let reason = skipReason(
            settings: settings,
            hasSyncCredentials: hasSyncCredentials
        ) {
            return .skipped(reason)
        }

        guard let budgetID = settings.selectedBudgetID else {
            return .skipped("Skipped: no selected budget")
        }
        guard let budget = budget(
            for: budgetID,
            settings: settings,
            selectedBudget: selectedBudget,
            budgets: budgets
        ) else {
            return .skipped("Skipped: selected budget metadata unavailable")
        }

        let result = try await withTimeLimit(timeLimit) {
            try await sync(
                budget: budget,
                budgetID: budgetID,
                serverURLString: settings.localFirstServerURLString,
                store: store
            )
        }
        return .synced(result)
    }

    private func sync(
        budget: ActualBudget,
        budgetID: String,
        serverURLString: String,
        store: LocalFirstActualStore
    ) async throws -> BackgroundTransactionRefreshResult {
        if Task.isCancelled {
            throw CancellationError()
        }

        let results = try await store.syncAndFindNewTransactions(
            budget: budget,
            serverURLString: serverURLString
        )

        if Task.isCancelled {
            throw CancellationError()
        }

        let pendingTransactions = try results.compactMap { result -> BackgroundPendingTransactions? in
            if Task.isCancelled {
                throw CancellationError()
            }
            guard !result.newTransactionIDs.isEmpty else {
                return nil
            }
            return BackgroundPendingTransactions(
                accountID: result.account.id,
                transactionIDs: result.newTransactionIDs
            )
        }

        return BackgroundTransactionRefreshResult(
            budgetID: budgetID,
            accountCount: results.count,
            pendingTransactions: pendingTransactions
        )
    }

    private func withTimeLimit<Result: Sendable>(
        _ timeLimit: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        try await Actualist.withTimeLimit(timeLimit, timeoutError: BackgroundTransactionRefreshRunnerError.timeLimitExceeded, operation: operation)
    }

    private func skipReason(
        settings: AppSettings,
        hasSyncCredentials: Bool
    ) -> String? {
        var reasons: [String] = []
        // The background task serves both toggles (plan Phase 6): alerts and
        // background bank sync. With only bank sync on, the pull still runs.
        if !settings.backgroundTransactionRefreshEnabled,
           !settings.simplefinBackgroundSyncEnabled {
            reasons.append("alerts and bank sync disabled")
        }
        if settings.selectedBudgetID == nil {
            reasons.append("no selected budget")
        }
        if !hasSyncCredentials {
            reasons.append("credentials missing")
        }

        guard !reasons.isEmpty else {
            return nil
        }
        return "Skipped: \(reasons.joined(separator: ", "))"
    }

    private func budget(
        for budgetID: String,
        settings: AppSettings,
        selectedBudget: ActualBudget?,
        budgets: [ActualBudget]
    ) -> ActualBudget? {
        if let selectedBudget, selectedBudget.syncID == budgetID {
            return selectedBudget
        }
        if let budget = budgets.first(where: { $0.syncID == budgetID }) {
            return budget
        }
        guard let fileID = settings.selectedLocalFirstFileID else {
            return nil
        }
        return ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: settings.selectedLocalFirstGroupID,
            name: settings.selectedBudgetName ?? "Selected Budget",
            state: nil
        )
    }
}

enum BackgroundBankSyncStepError: Error {
    case timedOut
}
