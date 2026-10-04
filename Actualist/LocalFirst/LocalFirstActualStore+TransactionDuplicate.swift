import Foundation

extension LocalFirstActualStore: TransactionDuplicateRepositoryProtocol {
    func reviewTransactionDuplicate(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionDuplicateReview {
        let database = try requireDatabase(for: context.budgetID)
        try requireDuplicateSession(context, database: database)
        let review = try await database.reviewTransactionDuplicate(
            context: context,
            selections: selections
        )
        try requireDuplicateSession(context, database: database)
        return review
    }

    func commitTransactionDuplicate(
        review: TransactionDuplicateReview
    ) async throws -> TransactionDuplicateOutcome {
        try Task.checkCancellation()
        let database = try requireDatabase(for: review.context.budgetID)
        let generation = review.context.sessionGeneration
        try requireDuplicateSession(review.context, database: database)
        let receipt = try await database.commitTransactionDuplicate(review: review)

        // Once SQLite commits, keep receipt delivery independent of caller
        // cancellation. Cache publication can be retried from the durable rows.
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
                    accountIDs: receipt.changed.accounts,
                    monthIDs: receipt.changed.months
                )
            }
        )
        return TransactionDuplicateOutcome(
            receipt: receipt,
            refreshPending: tail.refreshPending,
            sessionCurrent: tail.sessionCurrent
        )
    }

    private func requireDuplicateSession(
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
