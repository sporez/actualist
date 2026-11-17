import Foundation
import GRDB

struct BudgetActionLogPage: Equatable, Sendable {
    var records: [BudgetActionRecord]
    /// Rows present in the log that could not be decoded.
    var skippedRowCount: Int
}

/// Local-only action log persistence. `actualist_action_log` follows the
/// `actualist_outbox` pattern: created inside the imported budget SQLite, never
/// synced, wiped when a reimport replaces `db.sqlite`. Rows hold display
/// strings and amounts, so they are financial data: never logged, exported, or
/// included in diagnostics.
enum ActionLogStorageSQL {
    static let actionLogRetentionLimit = 25

    static func ensureActionLog(in database: isolated BudgetDatabase, db: Database) throws {
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
                source TEXT NOT NULL,
                mode_identity_json TEXT
            )
            """)
        database.columnSetCache["actualist_action_log"] = nil
        let columns = try database.columnSet(for: "actualist_action_log", db: db)
        if !columns.contains("mode_identity_json") {
            try db.execute(sql: "ALTER TABLE actualist_action_log ADD COLUMN mode_identity_json TEXT")
            database.columnSetCache["actualist_action_log"] = nil
        }
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS actualist_action_log_created_at
                ON actualist_action_log(created_at DESC)
            """)
        // Invalidate the cached miss. Caching true here would survive a transaction rollback.
        database.tableExistsCache["actualist_action_log"] = nil
    }

    static func insertActionLogRecord(_ record: BudgetActionRecord, db: Database) throws {
        let encoder = JSONEncoder()
        let modeIdentityJSON = try record.modeIdentity.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        try db.execute(
            sql: """
                INSERT INTO actualist_action_log
                    (id, created_at, kind, status, month, summary_json, inverse_json,
                     affected_json, forward_ts_start, forward_ts_end, undone_at,
                     undone_by_action_id, source, mode_identity_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
                """,
            arguments: [
                record.id,
                SyncTimestamp.wallTimeString(for: record.createdAt),
                record.kind.rawValue,
                record.status.rawValue,
                record.month,
                String(decoding: try encoder.encode(record.summary), as: UTF8.self),
                String(decoding: try encoder.encode(record.inverse), as: UTF8.self),
                String(decoding: try encoder.encode(record.affectedCategoryIDs), as: UTF8.self),
                record.forwardTimestampStart,
                record.forwardTimestampEnd,
                record.source.rawValue,
                modeIdentityJSON
            ]
        )
    }

    /// Newest first. Empty when the table does not exist (fresh import before
    /// the first recorded write), which is the reimport / first-launch state.
    /// `limit` nil returns every retained row (retention already bounds the
    /// table); rows that cannot be decoded are skipped, not fatal.
    static func recentBudgetActions(limit: Int? = nil, in database: isolated BudgetDatabase) throws -> [BudgetActionRecord] {
        try recentBudgetActionPage(limit: limit, in: database).records
    }

    static func recentBudgetActionPage(limit: Int? = nil, in database: isolated BudgetDatabase) throws -> BudgetActionLogPage {
        try database.queue.read { db in
            guard try database.tableExists("actualist_action_log", db: db) else {
                return BudgetActionLogPage(records: [], skippedRowCount: 0)
            }
            let modeColumn = try database.columnSet(for: "actualist_action_log", db: db).contains("mode_identity_json")
                ? ", mode_identity_json"
                : ""
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, created_at, kind, status, month, summary_json, inverse_json,
                           affected_json, forward_ts_start, forward_ts_end, source\(modeColumn)
                    FROM actualist_action_log
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit.map { max($0, 0) } ?? -1]
            )
            var records: [BudgetActionRecord] = []
            var skipped = 0
            for row in rows {
                // A row written by a newer build (unknown kind) or with a bad
                // payload must not hide every other record.
                if let record = try? decodeActionLogRow(row) {
                    records.append(record)
                } else {
                    skipped += 1
                }
            }
            return BudgetActionLogPage(records: records, skippedRowCount: skipped)
        }
    }

    private static func decodeActionLogRow(_ row: Row) throws -> BudgetActionRecord {
        let decoder = JSONDecoder()
        guard let id = row["id"] as String?,
              let createdAtString = row["created_at"] as String?,
              let createdAt = SyncTimestamp.wallTimeDate(from: createdAtString),
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
        let modeIdentity: BudgetModeIdentity?
        if let identityJSON = row["mode_identity_json"] as String? {
            modeIdentity = try decoder.decode(BudgetModeIdentity.self, from: Data(identityJSON.utf8))
        } else {
            modeIdentity = nil
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
            source: source,
            modeIdentity: modeIdentity
        )
    }

    static func actionLogRecord(id: String, in database: isolated BudgetDatabase) throws -> BudgetActionRecord? {
        try database.queue.read { db in
            guard try database.tableExists("actualist_action_log", db: db) else {
                return nil
            }
            let modeColumn = try database.columnSet(for: "actualist_action_log", db: db).contains("mode_identity_json")
                ? ", mode_identity_json"
                : ""
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, created_at, kind, status, month, summary_json, inverse_json,
                           affected_json, forward_ts_start, forward_ts_end, source\(modeColumn)
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

    static func markActionLogUndone(id: String, now: Date, db: Database) throws {
        try db.execute(
            sql: """
                UPDATE actualist_action_log
                SET status = ?, undone_at = ?
                WHERE id = ? AND status = ?
                """,
            arguments: [
                BudgetActionStatus.undone.rawValue,
                SyncTimestamp.wallTimeString(for: now),
                id,
                BudgetActionStatus.applied.rawValue
            ]
        )
        guard db.changesCount == 1 else {
            throw LocalFirstError.refusedChange("This action is no longer applied, so it cannot be undone.")
        }
    }

    /// Count and newest timestamp only. Never reads summary or inverse JSON.
    static func actionLogDiagnosticSnapshot(in database: isolated BudgetDatabase) throws -> ActionLogDiagnosticSnapshot {
        try database.queue.read { db in
            guard try database.tableExists("actualist_action_log", db: db) else {
                return .empty
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_action_log") ?? 0
            guard count > 0,
                  let newest = try String.fetchOne(
                    db,
                    sql: "SELECT MAX(created_at) FROM actualist_action_log"
                  ),
                  let date = SyncTimestamp.wallTimeDate(from: newest) else {
                return ActionLogDiagnosticSnapshot(count: count, newestCreatedAt: nil)
            }
            return ActionLogDiagnosticSnapshot(count: count, newestCreatedAt: date)
        }
    }

    /// Keep the newest 25 money-flow rows. Metadata in that time window stays
    /// and does not consume a slot. If the log is metadata-only, keep 25 rows.
    static func pruneActionLogKeepingMoneyFlowWindow(limit: Int, db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, kind, created_at FROM actualist_action_log
                ORDER BY created_at DESC, id DESC
                """
        )
        guard !rows.isEmpty else { return }
        var moneyFlowIDs: [String] = []
        var metadata: [(id: String, createdAt: String, idTie: String)] = []
        for row in rows {
            guard let id = row["id"] as String?,
                  let kindValue = row["kind"] as String?,
                  let createdAt = row["created_at"] as String?,
                  let kind = BudgetActionKind(rawValue: kindValue) else {
                continue
            }
            if kind.isMoneyFlow {
                if moneyFlowIDs.count < limit {
                    moneyFlowIDs.append(id)
                }
            } else {
                metadata.append((id, createdAt, id))
            }
        }
        var keep = Set(moneyFlowIDs)
        if let oldestKept = moneyFlowIDs.last {
            let oldestRow = rows.first { ($0["id"] as String?) == oldestKept }
            let oldestCreated = oldestRow?["created_at"] as String? ?? ""
            for item in metadata {
                if item.createdAt > oldestCreated
                    || (item.createdAt == oldestCreated && item.idTie >= oldestKept) {
                    keep.insert(item.id)
                }
            }
        } else {
            keep.formUnion(metadata.prefix(limit).map(\.id))
        }
        let allIDs = rows.compactMap { $0["id"] as String? }
        let stale = allIDs.filter { !keep.contains($0) }
        guard !stale.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: stale.count).joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM actualist_action_log WHERE id IN (\(placeholders))",
            arguments: StatementArguments(stale)
        )
    }

    /// Storage-level LIFO: undo is only offered for the newest applied row, and the
    /// commit re-checks it so a Shortcuts write that landed after the review sheet
    /// opened cannot be silently skipped. Automatic posts are not undoable and never
    /// block another row.
    static func requireNewestAppliedUndo(record: BudgetActionRecord, db: Database) throws {
        guard record.source != .automatic else {
            throw LocalFirstError.actionUndoBlocked("This was posted automatically and cannot be undone.")
        }
        let createdAt = SyncTimestamp.wallTimeString(for: record.createdAt)
        let filter = BudgetActionUndoOrder.participatingRowsFilter
        let newerApplied = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM actualist_action_log
                WHERE status = ?
                  AND \(filter.sql)
                  AND (created_at > ? OR (created_at = ? AND id > ?))
                """,
            arguments: StatementArguments(
                [BudgetActionStatus.applied.rawValue] + filter.arguments + [createdAt, createdAt, record.id]
            )
        ) ?? 0
        guard newerApplied == 0 else {
            throw LocalFirstError.actionUndoBlocked("Undo the newest action before this one.")
        }
    }
}
