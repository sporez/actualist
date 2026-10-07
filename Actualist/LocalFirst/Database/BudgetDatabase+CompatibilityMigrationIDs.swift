import Foundation
import GRDB
import OSLog

/// Compatibility DDL that equals an upstream Actual migration must also record
/// that migration's id in `__migrations__`. Upstream's migrations are not
/// idempotent (`CREATE TABLE account_groups`, `ADD COLUMN ...`), so an exported
/// or registered file whose columns exist without the id fails to open in
/// Actual web.
///
/// The ids come from the pinned v26.9.0 migrations
/// `packages/loot-core/migrations/1787013118115_add_account_groups.sql` and
/// `1780606215000_add_bank_sync_status.sql`. Nothing reads these ids as a
/// capability signal; `__migrations__` is a reserved dataset and never syncs.
extension BudgetDatabase {
    static let compatibilityMigrationIDsMigration = "compat-migration-ids-v1"
    static let accountGroupsUpstreamMigrationID: Int64 = 1_787_013_118_115
    static let bankSyncStatusUpstreamMigrationID: Int64 = 1_780_606_215_000

    private static let logger = Logger(subsystem: "com.sporez.actualist", category: "BudgetCompatibility")

    /// Upstream `account_groups` columns (name -> declared type, case-folded).
    private static let upstreamAccountGroupColumns: [String: String] = [
        "id": "text", "name": "text", "sort_order": "real", "tombstone": "integer"
    ]

    /// Records the account-groups migration when the physical schema equals
    /// upstream's. A differing `account_groups` table stays unrecorded.
    static func recordAccountGroupsMigrationID(in db: Database) throws {
        guard try hasMigrationsTable(in: db) else { return }
        let groupColumns = try declaredColumnTypes("account_groups", in: db)
        let accountColumns = try declaredColumnTypes("accounts", in: db)
        guard groupColumns == upstreamAccountGroupColumns, accountColumns["account_group_id"] == "text" else {
            logger.notice("account_groups schema differs from upstream; migration id left unrecorded")
            return
        }
        try insertMigrationID(accountGroupsUpstreamMigrationID, in: db)
    }

    /// Records the bank-sync-status migration when `accounts.bank_sync_status`
    /// has upstream's declared type.
    static func recordBankSyncStatusMigrationID(in db: Database) throws {
        guard try hasMigrationsTable(in: db) else { return }
        guard try declaredColumnTypes("accounts", in: db)["bank_sync_status"] == "text" else {
            logger.notice("accounts.bank_sync_status differs from upstream; migration id left unrecorded")
            return
        }
        try insertMigrationID(bankSyncStatusUpstreamMigrationID, in: db)
    }

    /// One-time backfill for files that compatibility already changed before it
    /// recorded ids. A column that exists without its id can only have come from
    /// compatibility, because every upstream migration records its own id.
    static func prepareCompatibilityMigrationIDs(in queue: DatabaseQueue) throws {
        try queue.write { db in
            guard try tableExists("accounts", in: db),
                  !(try localMigrationApplied(compatibilityMigrationIDsMigration, in: db)) else {
                return
            }
            try recordBankSyncStatusMigrationID(in: db)
            try recordAccountGroupsMigrationID(in: db)
            try recordLocalMigration(compatibilityMigrationIDsMigration, in: db)
        }
    }

    private static func hasMigrationsTable(in db: Database) throws -> Bool {
        try tableExists("__migrations__", in: db)
    }

    private static func tableExists(_ name: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [name]
        ) ?? false
    }

    private static func declaredColumnTypes(_ table: String, in db: Database) throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")") {
            guard let name = row["name"] as String? else { continue }
            result[name] = ((row["type"] as String?) ?? "").lowercased()
        }
        return result
    }

    private static func insertMigrationID(_ id: Int64, in db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO __migrations__ (id) VALUES (?)", arguments: [id])
    }
}
