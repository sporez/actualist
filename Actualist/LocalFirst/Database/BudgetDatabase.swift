import Foundation
import GRDB
import Synchronization

actor BudgetDatabase {
    /// Session write fence flag. Commits read it once at their start; teardown
    /// flips it without waiting (see `invalidateSessionWrites`).
    nonisolated let sessionWritesAllowed = Atomic<Bool>(true)
    let databaseURL: URL
    let queue: DatabaseQueue
    var localClock: HybridLogicalClock?
    /// Committed merkle trie (see `BudgetDatabase+Merkle.swift`); nil until first needed.
    var merkleCache: MerkleTrie?
    var merkleWorking: MerkleTrie?
    var merkleStaged: MerkleTrie?
    /// False until the once-per-file stored-clock rebuild has been checked (see `ensureMerkleTrieTrusted`).
    var merkleTrieChecked = false
    var tableExistsCache: [String: Bool] = [:]
    var columnSetCache: [String: Set<String>] = [:]
    /// Cross-launch cache authority. Every database path that changes Actual
    /// budget data calls this synchronously before its SQLite mutation can
    /// commit. Sync bookkeeping and open-time compatibility writes do not.
    let beforeBudgetDataMutation: @Sendable () throws -> Void

    static let bankSyncStatusCompatibilityMigration = "bank-sync-status-compatibility-v1"

    #if DEBUG
    /// Paths whose `init` ran on the main thread. Production opens go through
    /// `open(...)`, which runs off it; the many synchronous test fixtures keep
    /// calling `init` directly, so a precondition in `init` is not possible.
    static let debugMainThreadConstructionPaths = Mutex<Set<String>>([])
    #endif

    /// Builds and prepares the database off the main actor: SQLite open,
    /// compatibility passes, index creation and one-time history replays are
    /// blocking work. Every production open path uses this instead of `init`.
    @concurrent
    static func open(
        databaseURL: URL,
        localNodeID: String? = nil,
        beforeBudgetDataMutation: @escaping @Sendable () throws -> Void = {}
    ) async throws -> BudgetDatabase {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        return try BudgetDatabase(
            databaseURL: databaseURL,
            localNodeID: localNodeID,
            beforeBudgetDataMutation: beforeBudgetDataMutation
        )
    }

    init(
        databaseURL: URL,
        localNodeID: String? = nil,
        beforeBudgetDataMutation: @escaping @Sendable () throws -> Void = {}
    ) throws {
        #if DEBUG
        if Thread.isMainThread {
            Self.debugMainThreadConstructionPaths.withLock { _ = $0.insert(databaseURL.path) }
        }
        #endif
        self.databaseURL = databaseURL
        self.beforeBudgetDataMutation = beforeBudgetDataMutation
        queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: Self.untrustedFileConfiguration()
        )
        let compatibility = LaunchSignpost.begin(LaunchStage.budgetDatabaseCompatibility)
        defer { LaunchSignpost.end(LaunchStage.budgetDatabaseCompatibility, compatibility) }
        try Self.prepareBankSyncStatusCompatibility(in: queue)
        try Self.prepareBankSyncSchemaCompatibility(in: queue)
        try Self.preparePendingNewTransactionSchema(in: queue)
        try Self.prepareAccountGroupCompatibility(in: queue)
        try Self.prepareCompatibilityMigrationIDs(in: queue)
        try Self.prepareBudgetIdentity(in: queue)
        try Self.prepareMessagesTimestampIndex(in: queue)
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
                try recordBankSyncStatusMigrationID(in: db)
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
            guard try Self.hasRequiredBudgetSchema(in: db) else {
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

    struct TransactionWriteResult: Sendable {
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
        /// Timestamps of decryptable messages whose value could not be read. They are
        /// stored in `messages_crdt` but never applied.
        var quarantinedTimestamps: [String] = []

        static let empty = RemoteSyncApplyResult(
            appliedMessageCount: 0,
            insertedTransactionIDsByAccount: [:]
        )
    }

    struct ExistingTransactionState: Sendable {
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
