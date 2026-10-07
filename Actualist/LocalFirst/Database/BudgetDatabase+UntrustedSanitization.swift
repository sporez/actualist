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
        // One writer per file remains the norm; the timeout only absorbs a
        // brief overlap instead of failing at once with SQLITE_BUSY.
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            if deleteJournal {
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
        }
        return configuration
    }

    /// Proves a cached budget file opens and reads without running the
    /// compatibility writes that `init` performs. It reads only `sqlite_master`
    /// and, when present, the base `accounts` table, so a pre-compatibility
    /// file that a normal open would repair still validates. A file that is
    /// not a SQLite database, or whose tables are unreadable, throws.
    static func validateCachedBudgetReadOnly(at url: URL) throws {
        let queue = try DatabaseQueue(
            path: url.path,
            configuration: untrustedFileConfiguration(readonly: true)
        )
        try queue.read { db in
            let hasAccounts = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'accounts')"
            ) ?? false
            if hasAccounts {
                _ = try Row.fetchOne(db, sql: "SELECT id, name FROM accounts LIMIT 1")
            }
        }
    }

    /// Removes everything in the schema that is not Actual budget data:
    /// every `actualist_*` table and index (`ActualSyncDatasetPolicy.localTablePrefix`;
    /// all are recreated on open or on first use), the `kvcache` tables, every
    /// trigger, and every view that is not a `v_*` view. Upstream Actual has no
    /// triggers, and it creates and regenerates the `v_*` views itself, so
    /// those stay. Actualist never queries them. The identity table must not
    /// travel: `prepareBudgetIdentity` only inserts when absent, so a carried
    /// row would reuse the source budget's storage identity. Stripping is by rule, so a
    /// bookkeeping object added later cannot ship in an export or upload.
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
        let isLocalName: (String) -> Bool = { name in
            let lowered = name.lowercased()
            return lowered.hasPrefix(ActualSyncDatasetPolicy.localTablePrefix)
                || lowered == "kvcache" || lowered == "kvcache_key"
        }
        // Tables first: dropping one removes its indexes with it.
        for table in try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
        ) where isLocalName(table) {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table.quotedDatabaseIdentifier)")
        }
        // Remaining indexes cover domain tables, e.g. `messages_crdt`.
        for index in try String.fetchAll(
            db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"
        ) where isLocalName(index) {
            try db.execute(sql: "DROP INDEX IF EXISTS \(index.quotedDatabaseIdentifier)")
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
