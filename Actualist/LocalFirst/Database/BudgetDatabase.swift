import Foundation
import GRDB

actor BudgetDatabase {
    let databaseURL: URL
    let queue: DatabaseQueue
    var tableExistsCache: [String: Bool] = [:]
    var columnSetCache: [String: Set<String>] = [:]

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        queue = try DatabaseQueue(path: databaseURL.path)
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

    struct ExistingTransactionState {
        let account: String
        let isParent: Bool
        let transferID: String?
        let childIDs: [String]
        let pairedAccount: String?
        let pairedIsChild: Bool
    }
}
