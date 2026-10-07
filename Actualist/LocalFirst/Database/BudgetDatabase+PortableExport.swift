import Foundation
import GRDB

extension BudgetDatabase {
    /// Writes a consistent snapshot of the open database. This uses GRDB's
    /// backup API so an uncheckpointed WAL is included. It does not copy the
    /// live `db.sqlite` file.
    func writePortableSnapshot(to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        do {
            let configuration = Self.untrustedFileConfiguration(deleteJournal: true)
            let destination = try DatabaseQueue(
                path: destinationURL.path,
                configuration: configuration
            )
            try queue.backup(to: destination)
            try destination.write { db in
                try Self.sanitizeUntrustedSchema(in: db)
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
                configuration: untrustedFileConfiguration(readonly: true)
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
