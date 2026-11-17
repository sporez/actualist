import Foundation

/// Hold for next month on the store: the review of a hold or release and its
/// write with the reload that follows. The store owns it.
@MainActor
final class HoldWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func budgetHoldReview(budgetID: String, month: String) async throws -> BudgetHoldReview {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let review = try await BudgetHoldSQL.budgetHoldReview(month: month, in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        return review
    }

    func applyBudgetHoldAndRefresh(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        budgetID: String
    ) async throws -> LoadedBudgetMonth? {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        guard review.month == review.revision?.month,
              review.modeIdentity == review.revision?.modeIdentity else {
            throw LocalFirstError.budgetHoldReviewStale
        }
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)

        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await BudgetHoldSQL.budgetHoldMessages(
            command: command,
            review: review,
            builder: &builder,
            in: database
        )
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            messages,
            expectedMode: review.modeIdentity,
            expectedHoldReview: review
        )

        return await store.finishDurableBudgetWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            month: review.month
        )
    }
}

extension HoldWorkflows: BudgetHoldRepositoryProtocol { }
