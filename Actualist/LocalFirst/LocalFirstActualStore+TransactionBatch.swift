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
        let tail = await finishDurableCommit(
            database: database,
            budgetID: review.context.budgetID,
            requireSession: { [self] in
                try requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
            },
            reload: { [self] in
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
            }
        )
        return TransactionBatchOutcome(
            receipt: receipt,
            refreshPending: tail.refreshPending,
            sessionCurrent: tail.sessionCurrent
        )
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
