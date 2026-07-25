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

    struct ExistingTransactionState {
        let account: String
        let isParent: Bool
        let transferID: String?
        let childIDs: [String]
        let pairedAccount: String?
        let pairedIsChild: Bool
    }
}
