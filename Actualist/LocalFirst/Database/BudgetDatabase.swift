import Foundation
import GRDB
import Synchronization

actor BudgetDatabase {
    nonisolated let bankSyncWritesAllowed = Mutex(true)
    let databaseURL: URL
    let queue: DatabaseQueue
    var localClock: HybridLogicalClock?
    var tableExistsCache: [String: Bool] = [:]
    var columnSetCache: [String: Set<String>] = [:]
    /// Cross-launch cache authority. Every database path that changes Actual
    /// budget data calls this synchronously before its SQLite mutation can
    /// commit. Sync bookkeeping and open-time compatibility writes do not.
    let beforeBudgetDataMutation: @Sendable () throws -> Void

    static let bankSyncStatusCompatibilityMigration = "bank-sync-status-compatibility-v1"
    init(
        databaseURL: URL,
        localNodeID: String? = nil,
        beforeBudgetDataMutation: @escaping @Sendable () throws -> Void = {}
    ) throws {
        self.databaseURL = databaseURL
        self.beforeBudgetDataMutation = beforeBudgetDataMutation
        queue = try DatabaseQueue(path: databaseURL.path)
        let compatibility = LaunchSignpost.begin(LaunchStage.budgetDatabaseCompatibility)
        defer { LaunchSignpost.end(LaunchStage.budgetDatabaseCompatibility, compatibility) }
        try Self.prepareBankSyncStatusCompatibility(in: queue)
        try Self.prepareBankSyncSchemaCompatibility(in: queue)
        try Self.prepareAccountGroupCompatibility(in: queue)
        try Self.prepareBudgetIdentity(in: queue)
        if let localNodeID {
            let latestTimestamp = try queue.read { db in
                let hasMessagesTable = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM sqlite_master
                            WHERE type = 'table' AND name = 'messages_crdt'
                        )
                        """
                ) ?? false
                guard hasMessagesTable else {
                    return "1970-01-01T00:00:00.000Z-0000-0000000000000000"
                }
                return try String.fetchOne(
                    db,
                    sql: "SELECT MAX(timestamp) FROM messages_crdt"
                ) ?? "1970-01-01T00:00:00.000Z-0000-0000000000000000"
            }
            localClock = HybridLogicalClock(
                nodeID: localNodeID,
                lastTimestamp: latestTimestamp
            )
        } else {
            localClock = nil
        }
    }

    // Old imports may have retained bank_sync_status messages without the
    // physical column. Ensure the column on every open, but replay history only
    // once per file.
    private static func prepareBankSyncStatusCompatibility(in queue: DatabaseQueue) throws {
        try queue.write { db in
            let accountTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'accounts'
                    )
                    """
            ) ?? false
            guard accountTableExists else {
                return
            }

            let accountColumns = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                    .compactMap { $0["name"] as String? }
            )
            if !accountColumns.contains("bank_sync_status") {
                try db.execute(sql: "ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT")
            }

            guard !(try localMigrationApplied(bankSyncStatusCompatibilityMigration, in: db)) else {
                return
            }

            let messagesTableExists = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sqlite_master
                        WHERE type = 'table' AND name = 'messages_crdt'
                    )
                    """
            ) ?? false
            guard messagesTableExists else {
                try recordLocalMigration(bankSyncStatusCompatibilityMigration, in: db)
                return
            }

            let statusRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT row, value
                    FROM messages_crdt
                    WHERE dataset = 'accounts' AND column = 'bank_sync_status'
                    ORDER BY timestamp
                    """
            )
            var latestStatusByAccountID: [String: String?] = [:]
            for row in statusRows {
                guard let accountID = row["row"] as String?,
                      let serializedValue = row["value"] as String? else {
                    continue
                }
                if serializedValue.hasPrefix("S:") {
                    latestStatusByAccountID[accountID] = String(serializedValue.dropFirst(2))
                } else if serializedValue.hasPrefix("0:") {
                    latestStatusByAccountID[accountID] = .some(nil)
                }
            }

            for (accountID, status) in latestStatusByAccountID {
                try db.execute(
                    sql: "UPDATE accounts SET bank_sync_status = ? WHERE id = ?",
                    arguments: [status, accountID]
                )
            }
            try recordLocalMigration(bankSyncStatusCompatibilityMigration, in: db)
        }
    }

    func validateImportedBudget() throws {
        try queue.read { db in
            let integrityRows = try String.fetchAll(db, sql: "PRAGMA integrity_check")
            guard integrityRows == ["ok"] else {
                throw LocalFirstError.invalidDownloadedBudget
            }

            let requiredTables = ["accounts", "transactions", "categories", "category_groups"]
            for table in requiredTables {
                guard try Row.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [table]
                ) != nil else {
                    throw LocalFirstError.invalidDownloadedBudget
                }
            }

            let accounts = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                    .compactMap { $0["name"] as String? }
            )
            let transactions = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(transactions)")
                    .compactMap { $0["name"] as String? }
            )
            let categories = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(categories)")
                    .compactMap { $0["name"] as String? }
            )
            let categoryGroups = try Set(
                Row.fetchAll(db, sql: "PRAGMA table_info(category_groups)")
                    .compactMap { $0["name"] as String? }
            )
            guard accounts.isSuperset(of: ["id", "name"]),
                  transactions.isSuperset(of: ["id", "date", "amount"]),
                  transactions.contains("acct") || transactions.contains("account"),
                  categories.isSuperset(of: ["id", "name"]),
                  categoryGroups.isSuperset(of: ["id", "name"]) else {
                throw LocalFirstError.invalidDownloadedBudget
            }
        }
    }

    // Physical transaction columns vary across schema versions and test fixtures.
    struct TransactionRowColumns {
        let all: Set<String>
        let account: String
        let payee: String
        let isParent: String?
        let isChild: String?
        let transferID: String?
        let sortOrder: String?

        var hasNotes: Bool { all.contains("notes") }
        var hasCleared: Bool { all.contains("cleared") }
        var hasReconciled: Bool { all.contains("reconciled") }
        var hasTombstone: Bool { all.contains("tombstone") }
        var hasParentID: Bool { all.contains("parent_id") }
        var hasSchedule: Bool { all.contains("schedule") }
        var hasError: Bool { all.contains("error") }
        var hasStartingBalance: Bool { all.contains("starting_balance_flag") }
    }

    struct TransactionWriteResult {
        let messages: [ActualSyncDecodedMessage]
        let affectedAccountIDs: [String]
        let affectedTransactionIDs: [String]
    }

    struct TransactionFetchResult: Sendable {
        let transactions: [ActualTransaction]
        let reachedEnd: Bool
        let nextOffset: Int
    }

    struct RemoteSyncApplyResult: Equatable, Sendable {
        let appliedMessageCount: Int
        let insertedTransactionIDsByAccount: [String: [String]]

        static let empty = RemoteSyncApplyResult(
            appliedMessageCount: 0,
            insertedTransactionIDsByAccount: [:]
        )
    }

    struct ExistingTransactionState {
        let account: String
        let isParent: Bool
        let isChild: Bool
        let parentID: String?
        let transferID: String?
        let childIDs: [String]
        let pairedAccount: String?
        let pairedIsChild: Bool
    }
}

struct SplitTransactionRepairResult: Equatable, Sendable {
    var blankPayeeCount = 0
    var clearedCount = 0
    var deletedCount = 0
    var transfersFixedCount = 0
    var nonParentErrorsFixedCount = 0
    var parentCategoriesFixedCount = 0
    var mismatchedParentIDs: [String] = []
}
