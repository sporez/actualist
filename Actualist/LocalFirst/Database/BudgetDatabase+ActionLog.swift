import Foundation
import GRDB

/// Local-only action log persistence. `actualist_action_log` follows the
/// `actualist_outbox` pattern: created inside the imported budget SQLite, never
/// synced, wiped when a reimport replaces `db.sqlite`. Rows hold display
/// strings and amounts, so they are financial data: never logged, exported, or
/// included in diagnostics.
/// The action-log half of one atomic commit: what to record, from where,
/// under which id. Facts and the row insert run inside the write transaction.
struct ActionLogCommit: Sendable {
    var descriptor: BudgetActionDescriptor
    var source: BudgetActionSource
    var actionID: String
}

extension BudgetDatabase {
    static let actionLogRetentionLimit = 25

    /// Atomic "apply CRDT messages + insert the action-log row" commit. Inverse
    /// facts are captured from live cells inside the same write transaction so
    /// a concurrent caller cannot race the before-values; a failure anywhere
    /// rolls back both the write and the log row.
    @discardableResult
    func commitUserAction(
        _ drafts: [ActualSyncDecodedMessage],
        descriptor: BudgetActionDescriptor,
        source: BudgetActionSource,
        actionID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> Int {
        try commitLocalSyncMessagesAndEnqueue(
            drafts,
            now: now,
            actionLogCommit: ActionLogCommit(
                descriptor: descriptor,
                source: source,
                actionID: actionID
            )
        )
    }

    /// Gesture facts captured from live cells before the forward messages are
    /// applied.
    struct ActionLogFacts {
        var kind: BudgetActionKind
        var month: String
        var summary: BudgetActionSummary
        var inverse: BudgetActionInverse
        var affectedCategoryIDs: [String]

        func record(
            id: String,
            createdAt: Date,
            source: BudgetActionSource,
            forwardTimestampStart: String?,
            forwardTimestampEnd: String?
        ) -> BudgetActionRecord {
            BudgetActionRecord(
                id: id,
                createdAt: createdAt,
                kind: kind,
                status: .applied,
                month: month,
                summary: summary,
                inverse: inverse,
                affectedCategoryIDs: affectedCategoryIDs,
                forwardTimestampStart: forwardTimestampStart,
                forwardTimestampEnd: forwardTimestampEnd,
                source: source
            )
        }
    }

    func captureActionLogFacts(descriptor: BudgetActionDescriptor, db: Database) throws -> ActionLogFacts {
        switch descriptor {
        case .assign(let month, let categoryID, let budgeted):
            let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
            let before = try categoryBudgets(month: month, db: db)[trimmedCategoryID]?.budgeted ?? 0
            let assign = AssignBudgetAction(
                month: month,
                categoryID: trimmedCategoryID,
                before: before,
                after: budgeted
            )
            return ActionLogFacts(
                kind: .assign,
                month: month,
                summary: .assign(assign),
                inverse: .assign(assign),
                affectedCategoryIDs: [trimmedCategoryID]
            )
        case .move(let month, let legs):
            let budgets = try categoryBudgets(month: month, db: db)
            var affectedIDs = Set<String>()
            var previousBudgeted: [String: Int] = [:]
            for categoryID in legs.flatMap({ [$0.fromCategoryID, $0.toCategoryID] }).compactMap({ $0 }) {
                let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if affectedIDs.insert(trimmed).inserted {
                    previousBudgeted[trimmed] = budgets[trimmed]?.budgeted ?? 0
                }
            }
            return ActionLogFacts(
                kind: .move,
                month: month,
                summary: .move(MoveBudgetAction(month: month, legs: legs)),
                inverse: .move(MoveBudgetActionInverse(
                    month: month,
                    legs: legs,
                    previousBudgeted: previousBudgeted
                )),
                affectedCategoryIDs: affectedIDs.sorted()
            )
        case .template(let month, let mode, let assignments):
            let budgets = try categoryBudgets(month: month, db: db)
            var entries: [BudgetTemplateAssignmentFact] = []
            var affectedIDs: [String] = []
            for assignment in assignments.sorted(by: { $0.categoryID < $1.categoryID }) {
                let trimmed = assignment.categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                entries.append(BudgetTemplateAssignmentFact(
                    categoryID: trimmed,
                    before: budgets[trimmed]?.budgeted ?? 0,
                    after: assignment.amount
                ))
                affectedIDs.append(trimmed)
            }
            let template = TemplateBudgetAction(month: month, mode: mode, entries: entries)
            return ActionLogFacts(
                kind: .template,
                month: month,
                summary: .template(template),
                inverse: .template(template),
                affectedCategoryIDs: affectedIDs
            )
        }
    }

    func ensureActionLog(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS actualist_action_log (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                kind TEXT NOT NULL,
                status TEXT NOT NULL,
                month TEXT,
                summary_json TEXT NOT NULL,
                inverse_json TEXT NOT NULL,
                affected_json TEXT NOT NULL,
                forward_ts_start TEXT,
                forward_ts_end TEXT,
                undone_at TEXT,
                undone_by_action_id TEXT,
                source TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS actualist_action_log_created_at
                ON actualist_action_log(created_at DESC)
            """)
        // Invalidate the cached miss. Caching true here would survive a transaction rollback.
        tableExistsCache["actualist_action_log"] = nil
    }

    func insertActionLogRecord(_ record: BudgetActionRecord, db: Database) throws {
        let encoder = JSONEncoder()
        try db.execute(
            sql: """
                INSERT INTO actualist_action_log
                    (id, created_at, kind, status, month, summary_json, inverse_json,
                     affected_json, forward_ts_start, forward_ts_end, undone_at,
                     undone_by_action_id, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
                """,
            arguments: [
                record.id,
                Self.outboxDateString(record.createdAt),
                record.kind.rawValue,
                record.status.rawValue,
                record.month,
                String(decoding: try encoder.encode(record.summary), as: UTF8.self),
                String(decoding: try encoder.encode(record.inverse), as: UTF8.self),
                String(decoding: try encoder.encode(record.affectedCategoryIDs), as: UTF8.self),
                record.forwardTimestampStart,
                record.forwardTimestampEnd,
                record.source.rawValue
            ]
        )
    }

    func pruneActionLog(keeping limit: Int, db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM actualist_action_log
                WHERE id NOT IN (
                    SELECT id FROM actualist_action_log
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                )
                """,
            arguments: [limit]
        )
    }

    /// Newest first. Empty when the table does not exist (fresh import before
    /// the first recorded write), which is the reimport / first-launch state.
    func recentBudgetActions(limit: Int = BudgetDatabase.actionLogRetentionLimit) throws -> [BudgetActionRecord] {
        try queue.read { db in
            guard try tableExists("actualist_action_log", db: db) else {
                return []
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, created_at, kind, status, month, summary_json, inverse_json,
                           affected_json, forward_ts_start, forward_ts_end, source
                    FROM actualist_action_log
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            var records: [BudgetActionRecord] = []
            for row in rows {
                records.append(try decodeActionLogRow(row))
            }
            return records
        }
    }

    private func decodeActionLogRow(_ row: Row) throws -> BudgetActionRecord {
        let decoder = JSONDecoder()
        guard let id = row["id"] as String?,
              let createdAtString = row["created_at"] as String?,
              let createdAt = Self.outboxDate(createdAtString),
              let kindValue = row["kind"] as String?,
              let kind = BudgetActionKind(rawValue: kindValue),
              let statusValue = row["status"] as String?,
              let status = BudgetActionStatus(rawValue: statusValue),
              let summaryString = row["summary_json"] as String?,
              let inverseString = row["inverse_json"] as String?,
              let affectedString = row["affected_json"] as String?,
              let sourceValue = row["source"] as String?,
              let source = BudgetActionSource(rawValue: sourceValue) else {
            throw LocalFirstError.invalidLocalWrite("invalid action log row")
        }
        return BudgetActionRecord(
            id: id,
            createdAt: createdAt,
            kind: kind,
            status: status,
            month: row["month"] as String?,
            summary: try decoder.decode(BudgetActionSummary.self, from: Data(summaryString.utf8)),
            inverse: try decoder.decode(BudgetActionInverse.self, from: Data(inverseString.utf8)),
            affectedCategoryIDs: try decoder.decode([String].self, from: Data(affectedString.utf8)),
            forwardTimestampStart: row["forward_ts_start"] as String?,
            forwardTimestampEnd: row["forward_ts_end"] as String?,
            source: source
        )
    }

    func actionLogRecord(id: String) throws -> BudgetActionRecord? {
        try queue.read { db in
            guard try tableExists("actualist_action_log", db: db) else {
                return nil
            }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, created_at, kind, status, month, summary_json, inverse_json,
                           affected_json, forward_ts_start, forward_ts_end, source
                    FROM actualist_action_log
                    WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            return try decodeActionLogRow(row)
        }
    }

    // MARK: - Undo

    /// Live budgeted amounts for every category the inverse touches. A `nil`
    /// value means the category was deleted since the gesture was recorded.
    private func liveBudgetedForUndo(
        record: BudgetActionRecord,
        db: Database
    ) throws -> [String: Int?] {
        let budgets = try categoryBudgets(month: record.inverse.month, db: db)
        let categoryColumns: Set<String>
        let categoriesPresent = try tableExists("categories", db: db)
        if categoriesPresent {
            categoryColumns = try columnSet(for: "categories", db: db)
        } else {
            categoryColumns = []
        }
        var live: [String: Int?] = [:]
        for categoryID in record.affectedCategoryIDs {
            var alive = false
            if categoriesPresent {
                alive = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM categories
                        WHERE id = ? AND \(predicateForLiveRows(columns: categoryColumns))
                        LIMIT 1
                        """,
                    arguments: [categoryID]
                ) != nil
            }
            live[categoryID] = alive ? (budgets[categoryID]?.budgeted ?? 0) : nil
        }
        return live
    }

    /// Current → proposed amounts for the undo review, or the typed block
    /// explaining why the gesture cannot be undone.
    func actionUndoPreview(record: BudgetActionRecord) throws -> BudgetActionUndoPreview {
        try queue.read { db in
            let live = try liveBudgetedForUndo(record: record, db: db)
            switch BudgetActionUndo.evaluate(record: record, liveBudgeted: live) {
            case .clean(let targets):
                let entries = targets.keys.sorted().compactMap { categoryID -> BudgetActionUndoPreview.Entry? in
                    guard let current = live[categoryID] ?? nil,
                          let proposed = targets[categoryID] else {
                        return nil
                    }
                    return BudgetActionUndoPreview.Entry(
                        categoryID: categoryID,
                        current: current,
                        proposed: proposed
                    )
                }
                return BudgetActionUndoPreview(
                    actionID: record.id,
                    month: record.inverse.month,
                    entries: entries,
                    block: nil
                )
            case .blocked(let block):
                return BudgetActionUndoPreview(
                    actionID: record.id,
                    month: record.inverse.month,
                    entries: [],
                    block: block
                )
            }
        }
    }

    /// Atomic "restore the inverse + mark the row undone" commit. The inverse
    /// is re-evaluated against live cells inside the write transaction, so a
    /// concurrent write or sync pull that landed after the preview rolls the
    /// whole commit back instead of clobbering the newer values. The undo
    /// itself records no log row in v1 (Q6): the original row is marked
    /// `undone`.
    @discardableResult
    func commitActionUndo(record: BudgetActionRecord, now: Date = Date()) throws -> Int {
        guard var clock = localClock else {
            throw LocalFirstError.invalidLocalWrite("local clock is not configured")
        }
        let appliedCount: Int
        do {
            appliedCount = try queue.write { db in
                guard try tableExists("messages_crdt", db: db) else {
                    throw LocalFirstError.invalidLocalWrite("missing messages_crdt table")
                }
                try ensureLocalSyncOutbox(db)
                guard try tableExists("actualist_action_log", db: db) else {
                    throw LocalFirstError.invalidLocalWrite("there is nothing to undo")
                }
                try requireNewestAppliedUndo(record: record, db: db)

                let live = try liveBudgetedForUndo(record: record, db: db)
                let targets: [String: Int]
                switch BudgetActionUndo.evaluate(record: record, liveBudgeted: live) {
                case .clean(let cleanTargets):
                    targets = cleanTargets
                case .blocked(let block):
                    throw LocalFirstError.actionUndoBlocked(block.userFacingReason)
                }
                guard !targets.isEmpty else {
                    throw LocalFirstError.invalidLocalWrite("there is nothing to undo")
                }

                let monthValue = try Self.actualMonthValue(record.inverse.month)
                let table = try budgetTable(db: db)
                let columns = try requiredColumns(
                    table: table.rawValue,
                    required: ["month", "category", "amount"],
                    db: db
                )
                let baseTimestamp = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(timestamp) FROM messages_crdt"
                ) ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"
                var builder = LocalFirstSyncMessageBuilder()
                var drafts: [ActualSyncDecodedMessage] = []
                for categoryID in targets.keys.sorted() {
                    guard let amount = targets[categoryID] else { continue }
                    drafts += try assignCategoryBudgetMessages(
                        categoryID: categoryID,
                        budgeted: amount,
                        monthValue: monthValue,
                        table: table,
                        columns: columns,
                        db: db,
                        builder: &builder
                    )
                }
                let applied = try applyCommittedDrafts(
                    drafts,
                    clock: &clock,
                    now: now,
                    baseTimestamp: baseTimestamp,
                    db: db
                )
                try markActionLogUndone(id: record.id, now: now, db: db)
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

    /// Storage-level LIFO: undo is only offered for the newest applied row,
    /// and the commit re-checks it so a Shortcuts write that landed after the
    /// review sheet opened cannot be silently skipped.
    private func requireNewestAppliedUndo(record: BudgetActionRecord, db: Database) throws {
        let createdAt = Self.outboxDateString(record.createdAt)
        let newerApplied = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM actualist_action_log
                WHERE status = ?
                  AND (created_at > ? OR (created_at = ? AND id > ?))
                """,
            arguments: [
                BudgetActionStatus.applied.rawValue,
                createdAt,
                createdAt,
                record.id
            ]
        ) ?? 0
        guard newerApplied == 0 else {
            throw LocalFirstError.actionUndoBlocked("Undo the newest action before this one.")
        }
    }

    private func markActionLogUndone(id: String, now: Date, db: Database) throws {
        try db.execute(
            sql: """
                UPDATE actualist_action_log
                SET status = ?, undone_at = ?
                WHERE id = ? AND status = ?
                """,
            arguments: [
                BudgetActionStatus.undone.rawValue,
                Self.outboxDateString(now),
                id,
                BudgetActionStatus.applied.rawValue
            ]
        )
        guard db.changesCount == 1 else {
            throw LocalFirstError.invalidLocalWrite("this action is no longer applied")
        }
    }
}
