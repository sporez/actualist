import Foundation
import GRDB

extension BudgetDatabase {
    func fetchEntityNote(target: ActualNoteTarget) throws -> ActualNoteBody {
        try queue.read { db in
            guard try tableExists("notes", db: db) else {
                return ActualNoteBody(storedNote: nil)
            }
            let columns = try columnSet(for: "notes", db: db)
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

    func fetchUserNoteIDs(for noteIDs: Set<String>) throws -> Set<String> {
        try queue.read { db in
            try userNoteIDs(for: noteIDs, db: db)
        }
    }

    func userNoteIDs(for noteIDs: Set<String>, db: Database) throws -> Set<String> {
        guard !noteIDs.isEmpty else {
            return []
        }
        let sortedIDs = noteIDs.sorted()
        let placeholders = Array(repeating: "?", count: sortedIDs.count).joined(separator: ", ")
        return try userNoteIDs(
            sql: "SELECT id, note FROM notes WHERE id IN (\(placeholders))",
            arguments: StatementArguments(sortedIDs),
            db: db
        )
    }

    func allUserNoteIDs(db: Database) throws -> Set<String> {
        try userNoteIDs(
            sql: "SELECT id, note FROM notes",
            arguments: StatementArguments(),
            db: db
        )
    }

    private func userNoteIDs(
        sql: String,
        arguments: StatementArguments,
        db: Database
    ) throws -> Set<String> {
        guard try tableExists("notes", db: db) else {
            return []
        }
        let columns = try columnSet(for: "notes", db: db)
        guard columns.isSuperset(of: ["id", "note"]) else {
            return []
        }
        return Set(try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            let noteID = row["id"] as String? ?? ""
            let note = row["note"] as String?
            return ActualNoteBody(storedNote: note).hasUserNote ? noteID : nil
        })
    }

    func setEntityNoteMessages(
        target: ActualNoteTarget,
        userBody: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            _ = try requiredColumns(table: "notes", required: ["id", "note"], db: db)
            try validateEntityNoteTarget(target, db: db)

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

    private func validateEntityNoteTarget(
        _ target: ActualNoteTarget,
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

        guard try tableExists(table, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing note target")
        }
        let columns = try columnSet(for: table, db: db)
        guard try Row.fetchOne(
            db,
            sql: "SELECT id FROM \(quotedIdentifier(table)) WHERE id = ? AND \(predicateForLiveRows(columns: columns)) LIMIT 1",
            arguments: [target.entityID]
        ) != nil else {
            throw LocalFirstError.invalidLocalWrite("missing note target")
        }
    }
}
