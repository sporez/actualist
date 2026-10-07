import Foundation

extension LocalFirstActualStore {
    func budgetHoldReview(budgetID: String, month: String) async throws -> BudgetHoldReview {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let review = try await database.budgetHoldReview(month: month)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        return review
    }

    func applyBudgetHoldAndRefresh(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        budgetID: String
    ) async throws -> LoadedBudgetMonth? {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        guard review.month == review.revision?.month,
              review.modeIdentity == review.revision?.modeIdentity else {
            throw LocalFirstError.budgetHoldReviewStale
        }
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)

        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.budgetHoldMessages(
            command: command,
            review: review,
            builder: &builder
        )
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            messages,
            expectedMode: review.modeIdentity,
            expectedHoldReview: review
        )

        return await finishDurableBudgetWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            month: review.month
        )
    }
}
