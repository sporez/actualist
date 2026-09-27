import GRDB

extension BudgetDatabase {
    func budgetHoldReviewRevision(
        month: String,
        modeIdentity: BudgetModeIdentity,
        db: Database
    ) throws -> BudgetHoldReviewRevision {
        guard try tableExists("messages_crdt", db: db) else {
            return BudgetHoldReviewRevision(
                month: month,
                modeIdentity: modeIdentity,
                messageCount: 0,
                maxMessageTimestamp: nil
            )
        }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT COUNT(*) AS message_count, MAX(timestamp) AS max_timestamp FROM messages_crdt"
        )
        return BudgetHoldReviewRevision(
            month: month,
            modeIdentity: modeIdentity,
            messageCount: row?["message_count"] ?? 0,
            maxMessageTimestamp: row?["max_timestamp"]
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
