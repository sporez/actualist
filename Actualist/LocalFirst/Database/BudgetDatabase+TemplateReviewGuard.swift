import Foundation
import GRDB

/// Template review identity and its protected write precondition live here so
/// the general sync writer only has to invoke one focused validator.
extension BudgetDatabase {
    func budgetTemplateReviewRevision(month: String, db: Database) throws -> BudgetTemplateReviewRevision {
        let modeIdentity = try budgetModeIdentity(db: db)
        guard try tableExists("messages_crdt", db: db) else {
            return BudgetTemplateReviewRevision(
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
        return BudgetTemplateReviewRevision(
            month: month,
            modeIdentity: modeIdentity,
            messageCount: row?["message_count"] ?? 0,
            maxMessageTimestamp: row?["max_timestamp"]
        )
    }

    func validateBudgetTemplateReviewRevision(
        _ expected: BudgetTemplateReviewRevision?,
        db: Database
    ) throws {
        guard let expected else { return }
        guard try budgetTemplateReviewRevision(month: expected.month, db: db) == expected else {
            throw LocalFirstError.budgetTemplateReviewStale
        }
    }
}
