import Foundation
import GRDB

enum PortableDatabaseSQL {
    /// Writes a consistent snapshot of the open database. This uses GRDB's
    /// backup API so an uncheckpointed WAL is included. It does not copy the
    /// live `db.sqlite` file.
    static func writePortableSnapshot(to destinationURL: URL, in database: isolated BudgetDatabase) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        do {
            let configuration = BudgetDatabase.untrustedFileConfiguration(deleteJournal: true)
            let destination = try DatabaseQueue(
                path: destinationURL.path,
                configuration: configuration
            )
            try database.queue.backup(to: destination)
            try destination.write { db in
                try BudgetDatabase.sanitizeUntrustedSchema(in: db)
                let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard integrity == ["ok"] else {
                    throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
                }
                // The destination is forced to journal_mode = DELETE at open,
                // so committed writes already live in the main file.
                // Checkpointing a non-WAL database fails with SQLITE_LOCKED
                // ("database table is locked"), so only checkpoint when a WAL
                // actually exists.
                let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")?
                    .lowercased()
                if journalMode == "wal" {
                    try db.checkpoint(.truncate)
                }
            }
            // Dropped tables leave their rows in free pages; rewrite the file.
            try destination.vacuum()
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            removeSnapshotSidecars(of: destinationURL, fileManager: fileManager)
            throw error
        }
        removeSnapshotSidecars(of: destinationURL, fileManager: fileManager)
    }

    /// Read-only check for an already extracted portable database. Does not run
    /// open-time compatibility writes.
    static func validatePortableDatabase(at databaseURL: URL) throws {
        do {
            let queue = try DatabaseQueue(
                path: databaseURL.path,
                configuration: BudgetDatabase.untrustedFileConfiguration(readonly: true)
            )
            try queue.read { db in
                try validatePortableDatabaseContents(db)
            }
        } catch let error as PortableBudgetArchiveError {
            throw error
        } catch {
            // Unreadable or non-SQLite bytes fail the same integrity gate as a
            // database that reports corruption.
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
        }
    }

    private static func validatePortableDatabaseContents(_ db: Database) throws {
        guard try BudgetDatabase.hasRequiredBudgetSchema(in: db) else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
        }
        try PortableBudgetSchema.rejectUnknownMigrations(in: db)
    }

    private static func removeSnapshotSidecars(of databaseURL: URL, fileManager: FileManager) {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else {
                continue
            }
            try? fileManager.removeItem(at: sidecar)
        }
    }

    /// Tables whose tombstoned rows upstream's `resetSync` deletes.
    private static let syncResetTombstoneTables = [
        "transactions", "accounts", "payees", "categories", "category_groups", "schedules", "rules"
    ]

    /// Clears the carried CRDT history of a staged portable database, like
    /// upstream's `resetSync` (`loot-core/src/server/sync/reset.ts`): delete
    /// `messages_pending` (deferred messages from a newer client, 26.10.0+),
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
            configuration: BudgetDatabase.untrustedFileConfiguration(deleteJournal: true)
        )
        try queue.write { db in
            for table in ["messages_pending", "messages_crdt", "messages_clock"] where try SQLiteSchema.tableExists(table, in: db) {
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
            }
            for table in syncResetTombstoneTables where try SQLiteSchema.tableExists(table, in: db) {
                guard try SQLiteSchema.columns(of: table, in: db).contains("tombstone") else { continue }
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier) WHERE tombstone = 1")
            }
        }
        // ANALYZE and VACUUM cannot run inside a transaction.
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "ANALYZE")
        }
        try queue.vacuum()
    }
}
