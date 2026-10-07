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
        openBudget: BackgroundBudgetOpener?,
        timeLimit: Duration
    ) async throws -> BackgroundTransactionRefreshOutcome
}

/// Opens the refresh's budget through the app's session-transition owner and
/// reports whether a local baseline existed to diff against. `nil` lets the
/// store open it directly.
typealias BackgroundBudgetOpener = @MainActor (ActualBudget) async throws -> Bool

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
        openBudget: BackgroundBudgetOpener?,
        timeLimit: Duration
    ) async throws -> BackgroundTransactionRefreshOutcome {
        // Background refresh may run before the foreground scene restores AppState.
        if let reason = skipReason(
            settings: settings,
            hasSyncCredentials: hasSyncCredentials,
            keychain: store.keychain
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

        let result = try await runWithinDeadline(timeLimit) {
            try await sync(
                budget: budget,
                budgetID: budgetID,
                serverURLString: settings.localFirstServerURLString,
                store: store,
                openBudget: openBudget
            )
        }
        return .synced(result)
    }

    private func sync(
        budget: ActualBudget,
        budgetID: String,
        serverURLString: String,
        store: LocalFirstActualStore,
        openBudget: BackgroundBudgetOpener?
    ) async throws -> BackgroundTransactionRefreshResult {
        if Task.isCancelled {
            throw CancellationError()
        }

        let results = try await store.syncAndFindNewTransactions(
            budget: budget,
            serverURLString: serverURLString,
            openBudget: openBudget
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

    private func runWithinDeadline<Result: Sendable>(
        _ timeLimit: Duration,
        operation: @escaping @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withDeadline(timeLimit, timeoutError: BackgroundTransactionRefreshRunnerError.timeLimitExceeded, operation: operation)
    }

    private func skipReason(
        settings: AppSettings,
        hasSyncCredentials: Bool,
        keychain: KeychainStore
    ) -> String? {
        var reasons: [String] = []
        // Alerts and bank sync independently request the background pull.
        if !settings.wantsBackgroundAppRefresh {
            reasons.append("alerts and bank sync disabled")
        }
        if settings.selectedBudgetID == nil {
            reasons.append("no selected budget")
        }
        if !hasSyncCredentials {
            switch AppSessionRecovery.credentialAvailability(keychain: keychain) {
            case .unavailable: reasons.append("credentials unavailable on this device")
            case .absent, .available: reasons.append("credentials missing")
            }
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
        ActualBudget.resolved(
            budgetID: budgetID,
            selectedBudget: selectedBudget,
            budgets: budgets,
            settings: settings
        )
    }
}

enum BackgroundBankSyncStepError: Error {
    case timedOut
}
