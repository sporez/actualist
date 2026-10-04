import Foundation

extension LocalFirstActualStore: TransactionBatchRepositoryProtocol {
    func reviewTransactionBatch(
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionBatchReview {
        let database = try requireDatabase(for: context.budgetID)
        try requireBatchSession(context, database: database)
        let review = try await database.reviewTransactionBatch(
            context: context,
            intent: intent,
            selections: selections
        )
        try requireBatchSession(context, database: database)
        return review
    }

    func commitTransactionBatch(
        review: TransactionBatchReview,
        authorization: TransactionBatchAuthorization?
    ) async throws -> TransactionBatchOutcome {
        try Task.checkCancellation()
        let database = try requireDatabase(for: review.context.budgetID)
        let generation = review.context.sessionGeneration
        try requireBatchSession(review.context, database: database)
        let receipt = try await database.commitTransactionBatch(
            review: review,
            authorization: authorization
        )
        return await Task { @MainActor [self] in
            do {
                try requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
                if case .categorize = review.intent {
                    try await refreshRulesCache(database: database, budgetID: review.context.budgetID)
                }
                try requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: review.context.budgetID,
                    accountIDs: receipt.changedAccountIDs,
                    monthIDs: receipt.changedMonthIDs
                )
                try requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
                await schedulePendingLocalMessageFlush(database: database, budgetID: review.context.budgetID)
                try requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
                return TransactionBatchOutcome(receipt: receipt, refreshPending: false, sessionCurrent: true)
            } catch {
                var sessionCurrent = (try? requireSyncSession(
                    database: database,
                    budgetID: review.context.budgetID,
                    generation: generation
                )) != nil
                if sessionCurrent {
                    invalidateTransactionFeedCaches(budgetID: review.context.budgetID)
                    await schedulePendingLocalMessageFlush(database: database, budgetID: review.context.budgetID)
                    sessionCurrent = (try? requireSyncSession(
                        database: database,
                        budgetID: review.context.budgetID,
                        generation: generation
                    )) != nil
                }
                return TransactionBatchOutcome(
                    receipt: receipt,
                    refreshPending: true,
                    sessionCurrent: sessionCurrent
                )
            }
        }.value
    }

    private func requireBatchSession(
        _ context: TransactionSelectionContext,
        database: BudgetDatabase
    ) throws {
        guard context.sessionGeneration == budgetSessionGeneration else {
            throw CancellationError()
        }
        try requireSyncSession(
            database: database,
            budgetID: context.budgetID,
            generation: context.sessionGeneration
        )
    }
}
