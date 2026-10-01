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
        return await Task { @MainActor [self] in
            do {
                try requireSyncSession(
                    database: database,
                    budgetID: review.context.budgetID,
                    generation: generation
                )
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: review.context.budgetID,
                    accountIDs: receipt.changed.accounts,
                    monthIDs: receipt.changed.months
                )
                try requireSyncSession(
                    database: database,
                    budgetID: review.context.budgetID,
                    generation: generation
                )
                await schedulePendingLocalMessageFlush(
                    database: database,
                    budgetID: review.context.budgetID
                )
                try requireSyncSession(
                    database: database,
                    budgetID: review.context.budgetID,
                    generation: generation
                )
                return TransactionDuplicateOutcome(
                    receipt: receipt,
                    refreshPending: false,
                    sessionCurrent: true
                )
            } catch {
                var sessionCurrent = (try? requireSyncSession(
                    database: database,
                    budgetID: review.context.budgetID,
                    generation: generation
                )) != nil
                if sessionCurrent {
                    invalidateTransactionFeedCaches(budgetID: review.context.budgetID)
                    await schedulePendingLocalMessageFlush(
                        database: database,
                        budgetID: review.context.budgetID
                    )
                    sessionCurrent = (try? requireSyncSession(
                        database: database,
                        budgetID: review.context.budgetID,
                        generation: generation
                    )) != nil
                }
                return TransactionDuplicateOutcome(
                    receipt: receipt,
                    refreshPending: true,
                    sessionCurrent: sessionCurrent
                )
            }
        }.value
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
