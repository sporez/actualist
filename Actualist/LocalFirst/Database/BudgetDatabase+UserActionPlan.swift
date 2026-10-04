import Foundation
import GRDB

/// What one user gesture commits, built from the live rows of the write
/// transaction that applies it. A nil descriptor commits without a History row.
struct UserActionPlan<Outcome: Sendable>: Sendable {
    var drafts: [ActualSyncDecodedMessage]
    var descriptor: BudgetActionDescriptor?
    var learningTransactionIDs: Set<String> = []
    var outcome: Outcome
}

extension BudgetDatabase {
    /// Builds the plan inside the write transaction instead of from an earlier
    /// read. A remote message applied between a pre-read and the commit (a sync
    /// on this actor across an `await`) is therefore never overwritten with
    /// values derived from the stale rows. Review preconditions, action-log
    /// facts, CRDT cells, and outbox rows share that same transaction.
    func commitUserActionPlan<Outcome: Sendable>(
        source: BudgetActionSource,
        actionID: String = UUID().uuidString,
        now: Date = Date(),
        expectedMode: BudgetModeIdentity? = nil,
        reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition? = nil,
        expectedTemplateReviewRevision: BudgetTemplateReviewRevision? = nil,
        build: @Sendable (isolated BudgetDatabase, Database) throws -> UserActionPlan<Outcome>
    ) throws -> (outcome: Outcome, appliedCount: Int) {
        let review = LocalCommitReview(
            mode: expectedMode,
            bankLink: nil,
            reconciledMutation: reconciledMutationPrecondition,
            templateRevision: expectedTemplateReviewRevision,
            hold: nil,
            absentImportedIDs: nil
        )
        return try commitLocalPlan(now: now) { db in
            let plan = try build(self, db)
            let action = plan.descriptor.map {
                ActionLogCommit(
                    descriptor: $0,
                    source: source,
                    actionID: actionID,
                    learningTransactionIDs: plan.learningTransactionIDs
                )
            }
            try validateLocalCommit(review, drafts: plan.drafts, action: action, db: db)
            return LocalCommitPlan(drafts: plan.drafts, action: action, outcome: plan.outcome)
        }
    }
}
