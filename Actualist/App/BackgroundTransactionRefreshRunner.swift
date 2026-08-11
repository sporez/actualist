import Foundation

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
struct BackgroundTransactionRefreshRunner {
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
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeLimit)
                throw BackgroundTransactionRefreshRunnerError.timeLimitExceeded
            }
            defer {
                group.cancelAll()
            }
            guard let firstResult = try await group.next() else {
                throw CancellationError()
            }
            return firstResult
        }
    }

    private func skipReason(
        settings: AppSettings,
        hasSyncCredentials: Bool
    ) -> String? {
        var reasons: [String] = []
        if !settings.backgroundTransactionRefreshEnabled {
            reasons.append("alerts disabled")
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
