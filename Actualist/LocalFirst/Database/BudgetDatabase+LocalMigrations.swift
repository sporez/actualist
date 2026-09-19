import Foundation
import GRDB

extension BudgetDatabase {
    /// Records an Actualist-local one-time migration that has already run for
    /// this file.
    ///
    /// These rows are separate from Actual's own schema and from the CRDT
    /// message log: they say this build already transformed this file, so
    /// reopening a budget does not rescan and replay historical `messages_crdt`
    /// rows that only mattered before the transformation existed. A legacy or
    /// newly imported file has no watermark and still runs the migration once.
    ///
    /// Only work that is *added* to a file may be recorded this way. Work that a
    /// later sync could legitimately need again must not be.
    static func localMigrationApplied(_ name: String, in db: Database) throws -> Bool {
        guard try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'actualist_local_migrations'
                )
                """
        ) ?? false else {
            return false
        }
        return try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM actualist_local_migrations WHERE name = ?)",
            arguments: [name]
        ) ?? false
    }

    static func recordLocalMigration(_ name: String, in db: Database, appliedAt: Date = Date()) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS actualist_local_migrations (
                name TEXT PRIMARY KEY,
                applied_at TEXT NOT NULL
            )
            """)
        try db.execute(
            sql: "INSERT OR REPLACE INTO actualist_local_migrations (name, applied_at) VALUES (?, ?)",
            arguments: [name, String(appliedAt.timeIntervalSince1970)]
        )
    }
}
