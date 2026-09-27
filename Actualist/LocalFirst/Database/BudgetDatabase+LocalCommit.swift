import Foundation
import GRDB

extension BudgetDatabase {
    // Work on a clock copy so a rolled-back transaction cannot advance in-memory time.
    // Review validation, action-log facts, CRDT cells and outbox rows all share
    // the same SQLite transaction.
    func commitLocalSyncMessagesAndEnqueue(
        _ drafts: [ActualSyncDecodedMessage],
        now: Date = Date(),
        actionLogCommit: ActionLogCommit? = nil,
        expectedMode: BudgetModeIdentity? = nil,
        expectedBankLink: BankSyncLinkIdentity? = nil,
        reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition? = nil,
        expectedTemplateReviewRevision: BudgetTemplateReviewRevision? = nil,
        expectedHoldReview: BudgetHoldReview? = nil
    ) throws -> Int {
        let review = LocalCommitReview(
            mode: expectedMode,
            bankLink: expectedBankLink,
            reconciledMutation: reconciledMutationPrecondition,
            templateRevision: expectedTemplateReviewRevision,
            hold: expectedHoldReview
        )
        guard !drafts.isEmpty else {
            try queue.read { db in
                try validateLocalCommit(review, drafts: drafts, action: actionLogCommit, db: db)
            }
            return 0
        }
        guard var clock = localClock else {
            throw LocalFirstError.invalidLocalWrite("local clock is not configured")
        }
        try beforeBudgetDataMutation()

        let appliedCount: Int
        do {
            appliedCount = try queue.write { db in
                guard try tableExists("messages_crdt", db: db) else {
                    throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
                }
                try validateLocalCommit(review, drafts: drafts, action: actionLogCommit, db: db)
                try ensureLocalSyncOutbox(db)
                let baseTimestamp = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(timestamp) FROM messages_crdt"
                ) ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"

                let actionLogFacts = try actionLogCommit.map {
                    try captureActionLogFacts(descriptor: $0.descriptor, db: db)
                }
                let applied = try applyCommittedDrafts(
                    drafts,
                    clock: &clock,
                    now: now,
                    baseTimestamp: baseTimestamp,
                    db: db
                )
                if let actionLogCommit {
                    return try finishActionLogCommit(
                        actionLogCommit,
                        facts: actionLogFacts,
                        applied: applied,
                        clock: &clock,
                        now: now,
                        baseTimestamp: baseTimestamp,
                        db: db
                    )
                }
                return applied.appliedCount
            }
        } catch let error as BudgetModeWriteError {
            throw error
        } catch let error as ReconciledTransactionMutationError {
            throw error
        } catch let error as LocalFirstError {
            throw error
        } catch {
            throw LocalFirstError.invalidLocalWrite("the database transaction was rolled back")
        }
        localClock = clock
        return appliedCount
    }

    private struct LocalCommitReview {
        let mode: BudgetModeIdentity?
        let bankLink: BankSyncLinkIdentity?
        let reconciledMutation: ReconciledTransactionMutationPrecondition?
        let templateRevision: BudgetTemplateReviewRevision?
        let hold: BudgetHoldReview?
    }

    private func validateLocalCommit(
        _ review: LocalCommitReview,
        drafts: [ActualSyncDecodedMessage],
        action: ActionLogCommit?,
        db: Database
    ) throws {
        try validateBankSyncLink(review.bankLink, db: db)
        try validateBudgetTemplateReviewRevision(review.templateRevision, db: db)
        try validateBudgetHoldReview(review.hold, db: db)
        try validateBudgetWrite(
            drafts, expectedMode: review.mode, descriptor: action?.descriptor, db: db
        )
        try validateReconciledMutationPrecondition(review.reconciledMutation, db: db)
    }
}
