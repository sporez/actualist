import GRDB

extension BudgetDatabase {
    func budgetHoldReviewRevision(
        month: String,
        modeIdentity: BudgetModeIdentity,
        db: Database
    ) throws -> BudgetHoldReviewRevision {
        let watermark = try crdtMessageWatermark(db: db)
        return BudgetHoldReviewRevision(
            month: month,
            modeIdentity: modeIdentity,
            messageCount: watermark.messageCount,
            maxMessageTimestamp: watermark.maxMessageTimestamp
        )
    }

    /// Runs in the same SQLite transaction as the CRDT apply and outbox insert.
    func validateBudgetHoldReview(_ expected: BudgetHoldReview?, db: Database) throws {
        guard let expected else { return }
        guard expected.revision != nil,
              try budgetHoldReview(month: expected.month, db: db) == expected else {
            throw LocalFirstError.budgetHoldReviewStale
        }
    }
}
