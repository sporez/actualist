import Foundation
import GRDB

extension BudgetDatabase {
    /// Tables whose tombstoned rows upstream's `resetSync` deletes.
    static let syncResetTombstoneTables = [
        "transactions", "accounts", "payees", "categories", "category_groups", "schedules", "rules"
    ]

    /// Clears the carried CRDT history of a staged portable database, like
    /// upstream's `resetSync` (`loot-core/src/server/sync/reset.ts`): delete
    /// `messages_crdt` and `messages_clock`, delete tombstoned rows of the
    /// listed domain tables, then `ANALYZE` and `VACUUM`.
    ///
    /// A portable import registers a brand-new, empty server group. Carrying
    /// the source's messages would give the local merkle trie history the
    /// server never receives, so the first pull could never converge
    /// (`syncOutOfSync`). With the history cleared the trie rebuilds empty and
    /// the clock re-seeds from zero. Only the portable import path may call
    /// this: a downloaded or re-imported budget needs its `messages_crdt` for
    /// last-write-wins comparison. Tables or columns an older file lacks are
    /// skipped.
    static func resetSyncHistory(atStagedPortableDatabase url: URL) throws {
        let queue = try DatabaseQueue(
            path: url.path,
            configuration: untrustedFileConfiguration(deleteJournal: true)
        )
        try queue.write { db in
            for table in ["messages_crdt", "messages_clock"] where try hasTable(table, in: db) {
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
            }
            for table in syncResetTombstoneTables where try hasTable(table, in: db) {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table.quotedDatabaseIdentifier))")
                    .compactMap { $0["name"] as String? }
                guard columns.contains("tombstone") else { continue }
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier) WHERE tombstone = 1")
            }
        }
        // ANALYZE and VACUUM cannot run inside a transaction.
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "ANALYZE")
        }
        try queue.vacuum()
    }

    private static func hasTable(_ name: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [name]
        ) ?? false
    }
}
