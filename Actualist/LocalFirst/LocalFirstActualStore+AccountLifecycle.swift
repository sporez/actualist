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
    ) async throws -> AccountLifecycleMutationResult {
        try await applyAccountLifecycle(.rename(command), budgetID: budgetID)
    }

    func reopenAccountAndRefresh(
        budgetID: String,
        command: AccountReopenCommand
    ) async throws -> AccountLifecycleMutationResult {
        try await applyAccountLifecycle(.reopen(command), budgetID: budgetID)
    }

    func commitAccountLifecycleAndRefresh(
        reviewed: AccountLifecycleReview
    ) async throws -> AccountLifecycleCommitResult {
        try Task.checkCancellation()
        let budgetID = reviewed.identity.budgetID
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let result = try await database.commitAccountLifecycleReview(reviewed)
        if case .reviewChanged = result {
            return result
        }
        let unlinkedAccountID: String?
        if case .applied = result, reviewed.bankLink?.provider == .simpleFIN {
            unlinkedAccountID = reviewed.account.id
        } else {
            unlinkedAccountID = nil
        }
        return await finishAccountLifecycleCommit(
            result,
            database: database,
            budgetID: budgetID,
            generation: generation,
            unlinkedAccountID: unlinkedAccountID
        )
    }

    private func applyAccountLifecycle(
        _ command: AccountLifecycleMutationPrecondition,
        budgetID: String
    ) async throws -> AccountLifecycleMutationResult {
        try Task.checkCancellation()
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let result = try await database.commitAccountLifecycleMutation(command)

        return await finishAccountLifecycleCommit(
            result,
            database: database,
            budgetID: budgetID,
            generation: generation,
            unlinkedAccountID: nil
        )
    }

    private func finishAccountLifecycleCommit<Result: AccountLifecycleRefreshMarkable>(
        _ result: Result,
        database: BudgetDatabase,
        budgetID: String,
        generation: Int,
        unlinkedAccountID: String?
    ) async -> Result {
        // A committed account change is durable. Cancellation or refresh failure
        // must not turn it into a failed write that the UI invites the user to repeat.
        return await Task { @MainActor [self] in
            do {
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                if let unlinkedAccountID {
                    bankSyncGenerationByAccount[unlinkedAccountID] = nil
                }
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
                return result.markingRefreshPending()
            }
        }.value
    }
}
