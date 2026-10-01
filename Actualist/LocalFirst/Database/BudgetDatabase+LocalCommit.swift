import Foundation
import GRDB

extension BudgetDatabase {
    /// Session teardown waits for an already-running guarded commit; retained
    /// bank/account handles cannot start another guarded write after teardown.
    nonisolated func invalidateSessionWrites() {
        sessionWritesAllowed.withLock { $0 = false }
    }

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
        return try commitLocalPlan(now: now) { db in
            try validateLocalCommit(review, drafts: drafts, action: actionLogCommit, db: db)
            return LocalCommitPlan(drafts: drafts, action: actionLogCommit, outcome: ())
        }.appliedCount
    }

    struct LocalCommitPlan<Outcome: Sendable> {
        let drafts: [ActualSyncDecodedMessage]
        let action: ActionLogCommit?
        let outcome: Outcome
    }

    /// Preparation runs on the committing database handle. An empty plan is a
    /// successful no-op and must not touch the launch revision, clock or History.
    func commitLocalPlan<Outcome: Sendable>(
        now: Date = Date(),
        prepare: (Database) throws -> LocalCommitPlan<Outcome>
    ) throws -> (outcome: Outcome, appliedCount: Int) {
        var committedClock = localClock
        let result: (outcome: Outcome, appliedCount: Int)
        do {
            result = try queue.write { db in
                let plan = try prepare(db)
                guard !plan.drafts.isEmpty else { return (plan.outcome, 0) }
                guard var clock = committedClock else {
                    throw LocalFirstError.invalidLocalWrite("local clock is not configured")
                }
                guard try tableExists("messages_crdt", db: db) else {
                    throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
                }
                try beforeBudgetDataMutation()
                try ensureLocalSyncOutbox(db)
                let baseTimestamp = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(timestamp) FROM messages_crdt"
                ) ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"

                let actionLogFacts = try plan.action.map {
                    try captureActionLogFacts(descriptor: $0.descriptor, db: db)
                }
                let applied = try applyCommittedDrafts(
                    plan.drafts,
                    clock: &clock,
                    now: now,
                    baseTimestamp: baseTimestamp,
                    db: db
                )
                let appliedCount: Int
                if let actionLogCommit = plan.action {
                    appliedCount = try finishActionLogCommit(
                        actionLogCommit,
                        facts: actionLogFacts,
                        applied: applied,
                        clock: &clock,
                        now: now,
                        baseTimestamp: baseTimestamp,
                        db: db
                    )
                } else {
                    appliedCount = applied.appliedCount
                }
                committedClock = clock
                return (plan.outcome, appliedCount)
            }
        } catch let error as BudgetModeWriteError {
            throw error
        } catch let error as ReconciledTransactionMutationError {
            throw error
        } catch let error as AccountLifecycleCommandError {
            throw error
        } catch let error as ScheduleMutationCommandError {
            throw error
        } catch let error as ScheduleConversionError {
            throw error
        } catch let error as LocalFirstError {
            throw error
        } catch {
            throw LocalFirstError.invalidLocalWrite("the database transaction was rolled back")
        }
        localClock = committedClock
        return result
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
