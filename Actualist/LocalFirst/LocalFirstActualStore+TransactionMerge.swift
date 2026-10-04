import Foundation

extension LocalFirstActualStore: TransactionMergeRepositoryProtocol {
    func reviewTransactionMerge(
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String]
    ) async throws -> TransactionMergeReview {
        let database = try requireDatabase(for: context.budgetID)
        try requireMergeSession(context, database: database)
        let review = try await database.reviewTransactionMerge(
            context: context,
            orderedTransactionIDs: orderedTransactionIDs
        )
        try requireMergeSession(context, database: database)
        return review
    }

    func commitTransactionMerge(
        review: TransactionMergeReview,
        authorization: TransactionMergeAuthorization?
    ) async throws -> TransactionMergeOutcome {
        try Task.checkCancellation()
        let database = try requireDatabase(for: review.context.budgetID)
        let generation = review.context.sessionGeneration
        try requireMergeSession(review.context, database: database)
        let receipt = try await database.commitTransactionMerge(
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
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: review.context.budgetID,
                    accountIDs: receipt.changedAccountIDs
                )
            }
        )
        return TransactionMergeOutcome(
            receipt: receipt,
            refreshPending: tail.refreshPending,
            sessionCurrent: tail.sessionCurrent
        )
    }

    private func requireMergeSession(
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
