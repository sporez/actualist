import Foundation
import GRDB

extension BudgetDatabase {
    /// Session teardown waits for an already-running guarded commit; retained
    /// bank/account handles cannot start another guarded write after teardown.
    nonisolated func invalidateSessionWrites() {
        sessionWritesAllowed.withLock { $0 = false }
    }

    // Work on a clock copy so a rolled-back transaction cannot advance in-memory time.
    // Review validation, action-log facts, CRDT cells, outbox rows and durable
    // pending new-transaction rows all share the same SQLite transaction.
    func commitLocalSyncMessagesAndEnqueue(
        _ drafts: [ActualSyncDecodedMessage],
        now: Date = Date(),
        actionLogCommit: ActionLogCommit? = nil,
        expectedMode: BudgetModeIdentity? = nil,
        expectedBankLink: BankSyncLinkIdentity? = nil,
        reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition? = nil,
        expectedTemplateReviewRevision: BudgetTemplateReviewRevision? = nil,
        expectedHoldReview: BudgetHoldReview? = nil,
        pendingNewTransactions: PendingNewTransactionCommit? = nil,
        expectedAbsentImportedIDs: ImportedIDAbsence? = nil
    ) throws -> Int {
        let review = LocalCommitReview(
            mode: expectedMode,
            bankLink: expectedBankLink,
            reconciledMutation: reconciledMutationPrecondition,
            templateRevision: expectedTemplateReviewRevision,
            hold: expectedHoldReview,
            absentImportedIDs: expectedAbsentImportedIDs
        )
        guard !drafts.isEmpty else {
            try queue.read { db in
                try validateLocalCommit(review, drafts: drafts, action: actionLogCommit, db: db)
            }
            return 0
        }
        return try commitLocalPlan(now: now) { db in
            try validateLocalCommit(review, drafts: drafts, action: actionLogCommit, db: db)
            return LocalCommitPlan(
                drafts: drafts,
                action: actionLogCommit,
                outcome: (),
                pendingNewTransactions: pendingNewTransactions
            )
        }.appliedCount
    }

    struct LocalCommitPlan<Outcome: Sendable> {
        let drafts: [ActualSyncDecodedMessage]
        let action: ActionLogCommit?
        let outcome: Outcome
        var pendingNewTransactions: PendingNewTransactionCommit? = nil
    }

    /// Preparation runs on the committing database handle. An empty plan is a
    /// successful no-op and must not touch the launch revision, clock or History.
    ///
    /// This and `performActionUndoCommit` are the session write fence: the lock
    /// is held across the whole write, so teardown waits for an in-flight commit
    /// and a retained handle cannot start another one afterwards. `Mutex` is not
    /// reentrant; nothing inside a commit may take the fence again.
    func commitLocalPlan<Outcome: Sendable>(
        now: Date = Date(),
        prepare: (Database) throws -> LocalCommitPlan<Outcome>
    ) throws -> (outcome: Outcome, appliedCount: Int) {
        return try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            var committedClock = localClock
            let result: (outcome: Outcome, appliedCount: Int)
            do {
                result = try writeTrackingMerkle { db in
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
                    if let pendingNewTransactions = plan.pendingNewTransactions {
                        try recordPendingNewTransactions(pendingNewTransactions, db: db)
                    }
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
            } catch let error as any LocalCommitPassthroughError {
                throw error
            } catch {
                throw LocalFirstError.invalidLocalWrite("the database transaction was rolled back")
            }
            localClock = committedClock
            return result
        }
    }

    struct LocalCommitReview {
        let mode: BudgetModeIdentity?
        let bankLink: BankSyncLinkIdentity?
        let reconciledMutation: ReconciledTransactionMutationPrecondition?
        let templateRevision: BudgetTemplateReviewRevision?
        let hold: BudgetHoldReview?
        let absentImportedIDs: ImportedIDAbsence?
    }

    func validateLocalCommit(
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
        try validateImportedIDsAbsent(review.absentImportedIDs, db: db)
    }

    struct CommittedDraftsResult: Sendable {
        var appliedCount: Int
        var firstTimestamp: String?
        var lastTimestamp: String?
    }

    /// Applies pending-timestamp drafts inside an already-open write
    /// transaction: stamps hybrid-logical timestamps, validates, rejects
    /// superseded writes, applies cells, appends `messages_crdt`, and
    /// enqueues outbox rows. Shared by the forward commit and the History
    /// undo commit so the two paths can never diverge.
    func applyCommittedDrafts(
        _ drafts: [ActualSyncDecodedMessage],
        clock: inout HybridLogicalClock,
        now: Date,
        baseTimestamp: String,
        db: Database
    ) throws -> CommittedDraftsResult {
        var appliedCount = 0
        var insertedRows = Set<RowKey>()
        var firstTimestamp: String?
        var lastTimestamp: String?
        for draft in drafts.sorted(by: { $0.timestamp < $1.timestamp }) {
            let message = ActualSyncDecodedMessage(
                timestamp: try clock.next(now: now),
                dataset: draft.dataset,
                row: draft.row,
                column: draft.column,
                serializedValue: draft.serializedValue
            )
            try validateLocalMessage(message, db: db)

            if try hasSameOrNewerMessage(message, db: db) {
                throw LocalFirstError.localWriteSuperseded
            }

            let rowKey = RowKey(message)
            let hasRow: Bool
            if insertedRows.contains(rowKey) {
                hasRow = true
            } else {
                hasRow = try rowExists(
                    table: message.dataset,
                    rowID: message.row,
                    db: db
                )
            }
            let value = try ActualSyncSQLiteValue(serialized: message.serializedValue)
            try apply(message: message, value: value, rowExists: hasRow, db: db)
            insertedRows.insert(rowKey)
            try insertCRDTMessage(message, db: db)
            try insertLocalSyncOutboxMessage(
                message,
                baseTimestamp: baseTimestamp,
                db: db
            )
            if firstTimestamp == nil {
                firstTimestamp = message.timestamp
            }
            lastTimestamp = message.timestamp
            appliedCount += 1
        }
        return CommittedDraftsResult(
            appliedCount: appliedCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp
        )
    }
}
