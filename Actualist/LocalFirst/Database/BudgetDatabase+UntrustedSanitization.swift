import Foundation
import GRDB

extension BudgetDatabase {
    /// Connection settings for a budget file that did not come from this
    /// device's own writes. `trusted_schema = OFF` stops SQLite from running
    /// unsafe SQL functions referenced by views, triggers, or generated
    /// columns that a hostile file defines.
    static func untrustedFileConfiguration(
        readonly: Bool = false,
        deleteJournal: Bool = false
    ) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            if deleteJournal {
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
        }
        return configuration
    }

    /// Removes everything in the schema that is not Actual budget data:
    /// Actualist bookkeeping tables (`portableExportStrippedTables`), every
    /// trigger, and every view that is not a `v_*` view. Upstream Actual has no
    /// triggers, and it creates and regenerates the `v_*` views itself, so
    /// those stay. Actualist never queries them.
    static func sanitizeUntrustedSchema(in db: Database) throws {
        for trigger in try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"
        ) {
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger.quotedDatabaseIdentifier)")
        }
        for view in try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'view' AND name NOT LIKE 'v\\_%' ESCAPE '\\'"
        ) {
            try db.execute(sql: "DROP VIEW IF EXISTS \(view.quotedDatabaseIdentifier)")
        }
        for table in portableExportStrippedTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table.quotedDatabaseIdentifier)")
        }
    }

    /// Sanitizes an extracted, not yet installed database in place. Runs
    /// before the file is validated, installed, or opened as a budget, so a
    /// foreign outbox can never flush into the new sync group and a foreign
    /// storage identity is never reused. `VACUUM` rewrites the file so dropped
    /// rows do not linger in free pages. Throws `invalidDownloadedBudget` for
    /// bytes that are not a usable SQLite database.
    static func sanitizeUntrustedDatabase(at url: URL) throws {
        do {
            let queue = try DatabaseQueue(
                path: url.path,
                configuration: untrustedFileConfiguration(deleteJournal: true)
            )
            try queue.write { db in try sanitizeUntrustedSchema(in: db) }
            try queue.vacuum()
        } catch {
            throw LocalFirstError.invalidDownloadedBudget
        }
    }
}
