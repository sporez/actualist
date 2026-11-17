import Foundation

/// Review-and-commit actions on a transaction selection: batch edits,
/// duplicate and merge, each with its session checks and durable tail. The
/// store owns it; the feed caches stay on the store, which publishes them.
@MainActor
final class TransactionCommandWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    // MARK: - Batch

    func reviewTransactionBatch(
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionBatchReview {
        let database = try store.requireDatabase(for: context.budgetID)
        try requireBatchSession(context, database: database)
        let review = try await TransactionBatchSQL.reviewTransactionBatch(
            context: context,
            intent: intent,
            selections: selections,
            in: database
        )
        try requireBatchSession(context, database: database)
        return review
    }

    func commitTransactionBatch(
        review: TransactionBatchReview,
        authorization: TransactionBatchAuthorization?
    ) async throws -> TransactionBatchOutcome {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: review.context.budgetID)
        let generation = review.context.sessionGeneration
        try requireBatchSession(review.context, database: database)
        let receipt = try await TransactionBatchSQL.commitTransactionBatch(
            review: review,
            authorization: authorization,
            in: database
        )
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: review.context.budgetID,
            requireSession: { [self] in
                try store.requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
            },
            reload: { [self] in
                if case .categorize = review.intent {
                    try await store.rules.refreshRulesCache(database: database, budgetID: review.context.budgetID)
                }
                try store.requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
                try await store.reloadAfterTransactionMutation(
                    database: database,
                    budgetID: review.context.budgetID,
                    accountIDs: receipt.changedAccountIDs
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
        guard context.sessionGeneration == store.budgetSessionGeneration else {
            throw CancellationError()
        }
        try store.requireSyncSession(
            database: database,
            budgetID: context.budgetID,
            generation: context.sessionGeneration
        )
    }

    // MARK: - Duplicate

    func reviewTransactionDuplicate(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionDuplicateReview {
        let database = try store.requireDatabase(for: context.budgetID)
        try requireDuplicateSession(context, database: database)
        let review = try await TransactionDuplicateSQL.reviewTransactionDuplicate(
            context: context,
            selections: selections,
            in: database
        )
        try requireDuplicateSession(context, database: database)
        return review
    }

    func commitTransactionDuplicate(
        review: TransactionDuplicateReview
    ) async throws -> TransactionDuplicateOutcome {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: review.context.budgetID)
        let generation = review.context.sessionGeneration
        try requireDuplicateSession(review.context, database: database)
        let receipt = try await TransactionDuplicateSQL.commitTransactionDuplicate(review: review, in: database)

        // Once SQLite commits, keep receipt delivery independent of caller
        // cancellation. Cache publication can be retried from the durable rows.
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: review.context.budgetID,
            requireSession: { [self] in
                try store.requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
            },
            reload: { [self] in
                try await store.reloadAfterTransactionMutation(
                    database: database,
                    budgetID: review.context.budgetID,
                    accountIDs: receipt.changed.accounts
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
        guard context.sessionGeneration == store.budgetSessionGeneration else {
            throw CancellationError()
        }
        try store.requireSyncSession(
            database: database,
            budgetID: context.budgetID,
            generation: context.sessionGeneration
        )
    }

    // MARK: - Merge

    func reviewTransactionMerge(
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String]
    ) async throws -> TransactionMergeReview {
        let database = try store.requireDatabase(for: context.budgetID)
        try requireMergeSession(context, database: database)
        let review = try await TransactionMergeSQL.reviewTransactionMerge(
            context: context,
            orderedTransactionIDs: orderedTransactionIDs,
            in: database
        )
        try requireMergeSession(context, database: database)
        return review
    }

    func commitTransactionMerge(
        review: TransactionMergeReview,
        authorization: TransactionMergeAuthorization?
    ) async throws -> TransactionMergeOutcome {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: review.context.budgetID)
        let generation = review.context.sessionGeneration
        try requireMergeSession(review.context, database: database)
        let receipt = try await TransactionMergeSQL.commitTransactionMerge(
            review: review,
            authorization: authorization,
            in: database
        )
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: review.context.budgetID,
            requireSession: { [self] in
                try store.requireSyncSession(database: database, budgetID: review.context.budgetID, generation: generation)
            },
            reload: { [self] in
                try await store.reloadAfterTransactionMutation(
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
        guard context.sessionGeneration == store.budgetSessionGeneration else {
            throw CancellationError()
        }
        try store.requireSyncSession(
            database: database,
            budgetID: context.budgetID,
            generation: context.sessionGeneration
        )
    }
}

extension TransactionCommandWorkflows:
    TransactionBatchRepositoryProtocol,
    TransactionDuplicateRepositoryProtocol,
    TransactionMergeRepositoryProtocol { }
