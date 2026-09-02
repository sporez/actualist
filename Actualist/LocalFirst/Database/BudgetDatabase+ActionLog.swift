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
            let decoder = JSONDecoder()
            return try rows.map { row in
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
        }
    }
}
