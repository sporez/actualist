import Foundation
import GRDB

actor BudgetDatabase {
    let databaseURL: URL
    let queue: DatabaseQueue
    var localClock: HybridLogicalClock?
    var tableExistsCache: [String: Bool] = [:]
    var columnSetCache: [String: Set<String>] = [:]

    init(databaseURL: URL, localNodeID: String? = nil) throws {
        self.databaseURL = databaseURL
        queue = try DatabaseQueue(path: databaseURL.path)
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

    /// Resolved physical column names for the `transactions` table. Actual's CRDT messages use
    /// physical columns, which differ from the AQL field names: payee lives in `description`,
    /// account in `acct`, the split flags are `isParent`/`isChild`, and a transfer's paired-row
    /// link is `transferred_id`. Older/test schemas may use the snake_case variants, so probe.
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
        var hasTombstone: Bool { all.contains("tombstone") }
        var hasParentID: Bool { all.contains("parent_id") }
    }

    /// Messages plus the accounts/transactions a mutation touched, so the store reloads exactly
    /// the affected read caches.
    struct TransactionWriteResult {
        let messages: [ActualSyncDecodedMessage]
        let affectedAccountIDs: [String]
        let affectedTransactionIDs: [String]
    }

    struct TransactionFetchResult: Sendable {
        let transactions: [ActualTransaction]
        let reachedEnd: Bool
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
        let transferID: String?
        let childIDs: [String]
        let pairedAccount: String?
        let pairedIsChild: Bool
    }
}
