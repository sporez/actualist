import Foundation
import GRDB

extension BudgetDatabase {
    /// Flips the session write fence without blocking: a guarded commit that
    /// has not yet started is refused, so a retained bank/account handle cannot
    /// begin another write after teardown. A commit already inside its
    /// transaction runs to completion; a caller about to swap or delete the
    /// budget files awaits `quiesce()` after flipping.
    nonisolated func invalidateSessionWrites() {
        sessionWritesAllowed.store(false, ordering: .releasing)
    }

    /// Returns once every commit that was already running on this actor has
    /// finished. Commits are actor-isolated, so reaching this method means none
    /// is in flight; after `invalidateSessionWrites()` none can start.
    func quiesce() {}

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
        expectedAbsentImportedIDs: ImportedIDAbsence? = nil,
        expectedMatchedRows: MatchedRowsUnchanged? = nil
    ) throws -> Int {
        let review = LocalCommitReview(
            mode: expectedMode,
            bankLink: expectedBankLink,
            reconciledMutation: reconciledMutationPrecondition,
            templateRevision: expectedTemplateReviewRevision,
            hold: expectedHoldReview,
            absentImportedIDs: expectedAbsentImportedIDs,
            matchedRows: expectedMatchedRows
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
    /// This and `performActionUndoCommit` are the session write fence: each
    /// reads `sessionWritesAllowed` once before its transaction, so a retained
    /// handle cannot start a commit after teardown. The flag is never held
    /// across the write; file swaps and deletes await `quiesce()` instead.
    func commitLocalPlan<Outcome: Sendable>(
        now: Date = Date(),
        prepare: (Database) throws -> LocalCommitPlan<Outcome>
    ) throws -> (outcome: Outcome, appliedCount: Int) {
        guard sessionWritesAllowed.load(ordering: .acquiring) else {
            throw LocalFirstError.budgetNotOpened
        }
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
                    try ActionLogSQL.captureActionLogFacts(descriptor: $0.descriptor, in: self, db: db)
                }
                let applied = try applyCommittedDrafts(
                    plan.drafts,
                    clock: &clock,
                    now: now,
                    baseTimestamp: baseTimestamp,
                    db: db
                )
                if let pendingNewTransactions = plan.pendingNewTransactions {
                    try PendingNewTransactionSQL.recordPendingNewTransactions(pendingNewTransactions, in: self, db: db)
                }
                let appliedCount: Int
                if let actionLogCommit = plan.action {
                    appliedCount = try ActionLogSQL.finishActionLogCommit(
                        actionLogCommit,
                        facts: actionLogFacts,
                        applied: applied,
                        clock: &clock,
                        now: now,
                        baseTimestamp: baseTimestamp,
                        in: self,
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

    struct LocalCommitReview {
        let mode: BudgetModeIdentity?
        let bankLink: BankSyncLinkIdentity?
        let reconciledMutation: ReconciledTransactionMutationPrecondition?
        let templateRevision: BudgetTemplateReviewRevision?
        let hold: BudgetHoldReview?
        let absentImportedIDs: ImportedIDAbsence?
        var matchedRows: MatchedRowsUnchanged?
    }

    func validateLocalCommit(
        _ review: LocalCommitReview,
        drafts: [ActualSyncDecodedMessage],
        action: ActionLogCommit?,
        db: Database
    ) throws {
        try BankSyncLinkSQL.validateBankSyncLink(review.bankLink, in: self, db: db)
        try TemplatePreviewSQL.validateBudgetTemplateReviewRevision(review.templateRevision, in: self, db: db)
        try BudgetHoldSQL.validateBudgetHoldReview(review.hold, in: self, db: db)
        try BudgetModeSQL.validateBudgetWrite(
            drafts, expectedMode: review.mode, descriptor: action?.descriptor, in: self, db: db
        )
        try ReconciledMutationReviewSQL.validateReconciledMutationPrecondition(review.reconciledMutation, in: self, db: db)
        try ImportedIDPreconditionSQL.validateImportedIDsAbsent(review.absentImportedIDs, in: self, db: db)
        try ImportedIDPreconditionSQL.validateMatchedRowsUnchanged(review.matchedRows, in: self, db: db)
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

    /// Atomic "restore the inverse + mark the row undone" commit. The inverse
    /// is re-evaluated against live cells inside the write transaction, so a
    /// concurrent write or sync pull that landed after the preview rolls the
    /// whole commit back instead of clobbering the newer values. The undo
    /// itself records no log row in v1 (Q6): the original row is marked
    /// `undone`.
    @discardableResult
    func commitActionUndo(record: BudgetActionRecord, now: Date = Date()) throws -> Int {
        switch record.inverse {
        case .transactionBatch, .transactionDuplicate, .transactionMerge:
            try Task.checkCancellation()
            return try performActionUndoCommit(record: record, now: now)
        case .assign, .move, .template, .createTransaction, .editTransaction, .deleteTransaction,
                .categorize, .payee, .rule, .account, .carryover, .learningPref, .transactionMetadata:
            break
        }
        return try performActionUndoCommit(record: record, now: now)
    }

    private func performActionUndoCommit(record: BudgetActionRecord, now: Date) throws -> Int {
        guard sessionWritesAllowed.load(ordering: .acquiring) else {
            throw LocalFirstError.budgetNotOpened
        }
        guard var clock = localClock else {
            throw LocalFirstError.invalidLocalWrite("local clock is not configured")
        }
        let appliedCount: Int
        do {
            appliedCount = try writeTrackingMerkle { db in
                try Task.checkCancellation()
                guard try tableExists("messages_crdt", db: db) else {
                    throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
                }
                try ensureLocalSyncOutbox(db)
                guard try tableExists("actualist_action_log", db: db) else {
                    throw LocalFirstError.refusedChange("There is nothing to undo.")
                }
                try ActionLogStorageSQL.requireNewestAppliedUndo(record: record, db: db)

                let plan: BudgetActionUndoPlan
                switch try ActionLogSQL.evaluateActionUndo(record: record, in: self, db: db) {
                case .clean(let cleanPlan):
                    plan = cleanPlan
                case .blocked(let block):
                    throw LocalFirstError.actionUndoBlocked(block.userFacingReason)
                }

                let baseTimestamp = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(timestamp) FROM messages_crdt"
                ) ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"
                var builder = LocalFirstSyncMessageBuilder()
                let drafts = try ActionLogSQL.undoMessages(for: plan, record: record, builder: &builder, in: self, db: db)
                guard !drafts.isEmpty else {
                    throw LocalFirstError.refusedChange("There is nothing to undo.")
                }
                try beforeBudgetDataMutation()
                let applied = try applyCommittedDrafts(
                    drafts,
                    clock: &clock,
                    now: now,
                    baseTimestamp: baseTimestamp,
                    db: db
                )
                try ActionLogStorageSQL.markActionLogUndone(id: record.id, now: now, db: db)
                return applied.appliedCount
            }
        } catch let error as LocalFirstError {
            throw error
        } catch {
            throw LocalFirstError.invalidLocalWrite("the database transaction was rolled back")
        }
        localClock = clock
        return appliedCount
    }
}
