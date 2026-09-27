import Foundation

extension LocalFirstActualStore: AccountLifecycleRepositoryProtocol {
    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest
    ) async throws -> AccountLifecycleReview {
        let database = try requireDatabase(for: request.budgetID)
        let generation = budgetSessionGeneration
        let review = try await database.accountLifecycleReview(request: request)
        try requireSyncSession(database: database, budgetID: request.budgetID, generation: generation)
        return review
    }

    func renameAccountAndRefresh(
        budgetID: String,
        command: AccountRenameCommand
    ) async throws -> AccountLifecycleCommitResult {
        try await applyAccountLifecycle(.rename(command), budgetID: budgetID)
    }

    func reopenAccountAndRefresh(
        budgetID: String,
        command: AccountReopenCommand
    ) async throws -> AccountLifecycleCommitResult {
        try await applyAccountLifecycle(.reopen(command), budgetID: budgetID)
    }

    private func applyAccountLifecycle(
        _ command: AccountLifecycleMutationPrecondition,
        budgetID: String
    ) async throws -> AccountLifecycleCommitResult {
        try Task.checkCancellation()
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let result = try await database.commitAccountLifecycleMutation(command)

        // A committed account change is durable. Cancellation or refresh failure
        // must not turn it into a failed write that the UI invites the user to repeat.
        return await Task { @MainActor [self] in
            do {
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                try await reloadSelectedBudgetCache(budgetID: budgetID)
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                invalidateReports(budgetID: budgetID)
                try await reloadAccountCaches(database: database, budgetID: budgetID)
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                let diagnostics = try await database.actionLogDiagnosticSnapshot()
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                actionLogDiagnosticSnapshot = diagnostics
                await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
                return result
            } catch {
                if (try? requireSyncSession(
                    database: database, budgetID: budgetID, generation: generation
                )) != nil {
                    await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
                }
                switch result {
                case .applied(var outcome):
                    outcome.refreshPending = true
                    return .applied(outcome)
                case .noChange(var outcome):
                    outcome.refreshPending = true
                    return .noChange(outcome)
                case .reviewChanged:
                    return result
                }
            }
        }.value
    }
}
