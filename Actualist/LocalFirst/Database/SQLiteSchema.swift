import Foundation
import GRDB

/// Schema questions that need only a `Database` handle. Stateless and
/// uncached: `BudgetDatabase` keeps the cache and calls these on a miss, and
/// the open-time passes that run before an actor exists call them directly.
enum SQLiteSchema {
    static func tableExists(_ name: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [name]
        ) ?? false
    }

    static func columns(of table: String, in db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table.quotedDatabaseIdentifier))")
        return Set(rows.compactMap { $0["name"] as String? })
    }

    /// The first of `aliases` that `columns` has. Aliases name one concept
    /// across schema versions, so their order is the preference order.
    static func first(of aliases: [String], in columns: Set<String>) -> String? {
        aliases.first(where: columns.contains)
    }
}
