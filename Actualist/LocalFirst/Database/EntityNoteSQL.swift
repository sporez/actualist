import Foundation
import GRDB

enum EntityNoteSQL {
    static func fetchEntityNote(target: ActualNoteTarget, in database: isolated BudgetDatabase) throws -> ActualNoteBody {
        try database.queue.read { db in
            guard try database.tableExists("notes", db: db) else {
                return ActualNoteBody(storedNote: nil)
            }
            let columns = try database.columnSet(for: "notes", db: db)
            guard columns.isSuperset(of: ["id", "note"]) else {
                return ActualNoteBody(storedNote: nil)
            }
            let note = try String.fetchOne(
                db,
                sql: "SELECT note FROM notes WHERE id = ? LIMIT 1",
                arguments: [target.noteID]
            )
            return ActualNoteBody(storedNote: note)
        }
    }

    static func fetchUserNoteIDs(for noteIDs: Set<String>, in database: isolated BudgetDatabase) throws -> Set<String> {
        try database.queue.read { db in
            try userNoteIDs(for: noteIDs, in: database, db: db)
        }
    }

    private static func userNoteIDs(for noteIDs: Set<String>, in database: isolated BudgetDatabase, db: Database) throws -> Set<String> {
        guard !noteIDs.isEmpty else {
            return []
        }
        let sortedIDs = noteIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ", ")
        return try userNoteIDs(
            sql: "SELECT id, note FROM notes WHERE id IN (\(placeholders))",
            arguments: StatementArguments(sortedIDs),
            in: database,
            db: db
        )
    }

    /// User-note ids a month fetch can look up: that month's note and the
    /// notes of category groups and categories. Account, payee and other
    /// months' notes are never read. The scope is a superset of the live rows
    /// (tombstoned categories included), so every lookup resolves as it would
    /// against the whole table.
    static func userNoteIDs(inMonth month: String, in database: isolated BudgetDatabase, db: Database) throws -> Set<String> {
        var scopes = ["id = ?"]
        for table in ["categories", "category_groups"] where try database.tableExists(table, db: db) {
            guard try database.columnSet(for: table, db: db).contains("id") else { continue }
            scopes.append("id IN (SELECT id FROM \(table))")
        }
        return try userNoteIDs(
            sql: "SELECT id, note FROM notes WHERE \(scopes.joined(separator: " OR "))",
            arguments: ["budget-\(month)"],
            in: database,
            db: db
        )
    }

    private static func userNoteIDs(
        sql: String,
        arguments: StatementArguments,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Set<String> {
        guard try database.tableExists("notes", db: db) else {
            return []
        }
        let columns = try database.columnSet(for: "notes", db: db)
        guard columns.isSuperset(of: ["id", "note"]) else {
            return []
        }
        return Set(try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            let noteID = row["id"] as String? ?? ""
            let note = row["note"] as String?
            return ActualNoteBody(storedNote: note).hasUserNote ? noteID : nil
        })
    }

    static func setEntityNoteMessages(
        target: ActualNoteTarget,
        userBody: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            _ = try database.requiredColumns(table: "notes", required: ["id", "note"], db: db)
            try validateEntityNoteTarget(target, in: database, db: db)

            let existing = try Row.fetchOne(
                db,
                sql: "SELECT note FROM notes WHERE id = ? LIMIT 1",
                arguments: [target.noteID]
            )
            let existingNote = existing?["note"] as String?
            let persistedNote = ActualNoteBody(storedNote: existingNote)
                .persistedNote(userBody: userBody)
            guard persistedNote != existingNote else {
                return []
            }
            return [
                try builder.makeMessage(
                    dataset: "notes",
                    row: target.noteID,
                    column: "note",
                    value: persistedNote.map(LocalFirstSyncValue.string) ?? .null
                )
            ]
        }
    }

    private static func validateEntityNoteTarget(
        _ target: ActualNoteTarget,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let table: String
        switch target.kind {
        case .category:
            table = "categories"
        case .categoryGroup:
            table = "category_groups"
        case .account:
            table = "accounts"
        case .budgetMonth:
            return
        }

        guard try database.tableExists(table, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing note target")
        }
        let columns = try database.columnSet(for: table, db: db)
        guard try Row.fetchOne(
            db,
            sql: "SELECT id FROM \(database.quotedIdentifier(table)) WHERE id = ? AND \(database.predicateForLiveRows(columns: columns)) LIMIT 1",
            arguments: [target.entityID]
        ) != nil else {
            throw LocalFirstError.invalidLocalWrite("missing note target")
        }
    }
}
