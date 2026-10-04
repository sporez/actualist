import Foundation
import GRDB

/// Template review identity and its protected write precondition live here so
/// the general sync writer only has to invoke one focused validator.
extension BudgetDatabase {
    func budgetTemplateReviewRevision(month: String, db: Database) throws -> BudgetTemplateReviewRevision {
        let modeIdentity = try budgetModeIdentity(db: db)
        let watermark = try crdtMessageWatermark(db: db)
        return BudgetTemplateReviewRevision(
            month: month,
            modeIdentity: modeIdentity,
            messageCount: watermark.messageCount,
            maxMessageTimestamp: watermark.maxMessageTimestamp
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
