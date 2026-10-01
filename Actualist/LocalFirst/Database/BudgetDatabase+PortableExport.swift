import Foundation
import GRDB

extension BudgetDatabase {
    /// Local-only tables that must not travel in a portable snapshot.
    /// Domain tables stay. `actualist_local_migrations` and
    /// `actualist_budget_identity` are Actualist bookkeeping, not Actual
    /// domain tables, so they are stripped with the cache and outbox.
    /// The identity table in particular must not travel: `prepareBudgetIdentity`
    /// only inserts when absent, so a carried row would make the imported
    /// budget reuse the source budget's local storage identity.
    static let portableExportStrippedTables = [
        "kvcache",
        "kvcache_key",
        "actualist_action_log",
        "actualist_outbox",
        "actualist_local_migrations",
        "actualist_budget_identity"
    ]

    /// Writes a consistent snapshot of the open database. This uses GRDB's
    /// backup API so an uncheckpointed WAL is included. It does not copy the
    /// live `db.sqlite` file.
    func writePortableSnapshot(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            let destination = try DatabaseQueue(
                path: destinationURL.path,
                configuration: configuration
            )
            try queue.backup(to: destination)
            try destination.write { db in
                for table in Self.portableExportStrippedTables {
                    try db.execute(sql: "DROP TABLE IF EXISTS \(quotedIdentifier(table))")
                }
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
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
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
        let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        guard integrity == ["ok"] else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
        }

        let requiredTables = ["accounts", "transactions", "categories", "category_groups"]
        for table in requiredTables {
            guard try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table]
            ) != nil else {
                throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
            }
        }

        let accounts = try columnNames(for: "accounts", db: db)
        let transactions = try columnNames(for: "transactions", db: db)
        let categories = try columnNames(for: "categories", db: db)
        let categoryGroups = try columnNames(for: "category_groups", db: db)
        guard accounts.isSuperset(of: ["id", "name"]),
              transactions.isSuperset(of: ["id", "date", "amount"]),
              transactions.contains("acct") || transactions.contains("account"),
              categories.isSuperset(of: ["id", "name"]),
              categoryGroups.isSuperset(of: ["id", "name"]) else {
            throw PortableBudgetArchiveError(stage: .beforeInstall, reason: .integrity)
        }

        try PortableBudgetSchema.rejectUnknownMigrations(in: db)
    }

    private static func columnNames(for table: String, db: Database) throws -> Set<String> {
        Set(
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                .compactMap { $0["name"] as String? }
        )
    }

    private func removeSnapshotSidecars(of databaseURL: URL, fileManager: FileManager) {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else {
                continue
            }
            try? fileManager.removeItem(at: sidecar)
        }
    }
}
