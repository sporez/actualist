import Foundation
import GRDB

extension BudgetDatabase {
    // Work on a clock copy so a rolled-back transaction cannot advance in-memory time.
    // `actionLogCommit` captures facts and inserts the action-log row inside
    // the same write transaction, so the log row and the CRDT write commit or
    // roll back together.
    func commitLocalSyncMessagesAndEnqueue(
        _ drafts: [ActualSyncDecodedMessage],
        now: Date = Date(),
        actionLogCommit: ActionLogCommit? = nil,
        expectedMode: BudgetModeIdentity? = nil,
        expectedBankLink: BankSyncLinkIdentity? = nil,
        reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition? = nil,
        expectedTemplateReviewRevision: BudgetTemplateReviewRevision? = nil,
        expectedHoldReview: BudgetHoldReview? = nil,
        pendingNewTransactions: PendingNewTransactionCommit? = nil
    ) throws -> Int {
        guard !drafts.isEmpty else {
            try queue.read { db in
                try validateBankSyncLink(expectedBankLink, db: db)
                try validateBudgetTemplateReviewRevision(expectedTemplateReviewRevision, db: db)
                try validateBudgetHoldReview(expectedHoldReview, db: db)
                try validateBudgetWrite(drafts, expectedMode: expectedMode,
                    descriptor: actionLogCommit?.descriptor, db: db)
                try validateReconciledMutationPrecondition(
                    reconciledMutationPrecondition,
                    db: db
                )
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
                try validateBankSyncLink(expectedBankLink, db: db)
                try validateBudgetTemplateReviewRevision(expectedTemplateReviewRevision, db: db)
                try validateBudgetHoldReview(expectedHoldReview, db: db)
                try validateBudgetWrite(drafts, expectedMode: expectedMode,
                    descriptor: actionLogCommit?.descriptor, db: db)
                try validateReconciledMutationPrecondition(
                    reconciledMutationPrecondition,
                    db: db
                )
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
                if let pendingNewTransactions {
                    try recordPendingNewTransactions(pendingNewTransactions, db: db)
                }
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
        var insertedRows = Set<String>()
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

            let rowKey = message.dataset + message.row
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
            let value = try deserializeSyncValue(message.serializedValue)
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
