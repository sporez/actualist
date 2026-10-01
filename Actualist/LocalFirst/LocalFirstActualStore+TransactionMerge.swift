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
                    accountIDs: receipt.changedAccountIDs,
                    monthIDs: receipt.changedMonths
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
                return TransactionMergeOutcome(
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
                return TransactionMergeOutcome(
                    receipt: receipt,
                    refreshPending: true,
                    sessionCurrent: sessionCurrent
                )
            }
        }.value
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
