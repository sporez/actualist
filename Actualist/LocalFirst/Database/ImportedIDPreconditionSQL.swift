import Foundation
import GRDB

/// `imported_id` values an import is about to insert on one account.
/// The commit transaction re-checks them, because a remote row can land
/// between the import's read and its write.
struct ImportedIDAbsence: Sendable {
    let accountID: String
    let importedIDs: Set<String>

    init(accountID: String, importedIDs: some Sequence<String>) {
        self.accountID = accountID
        self.importedIDs = Set(importedIDs.compactMap(ImportedIDPreconditionSQL.normalizedImportedID))
    }
}

/// Concurrency 5.2c (audit CA-12): the matched rows an import will update,
/// exactly as the review saw them. The commit transaction re-reads them, so
/// an edit (local or synced) made after the review is not overwritten.
struct MatchedRowsUnchanged: Sendable {
    let accountID: String
    let reviewed: [BankSyncReconciliation.Existing]
}

enum ImportedIDPreconditionSQL {
    /// Ids compare exactly, as upstream's `imported_id = ?` does (sync.ts ~850):
    /// whitespace is trimmed and nothing else changes, so `A1` and `a1` are
    /// different ids for every importer.
    static func normalizedImportedID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Live imported ids on an account, trimmed (see `normalizedImportedID`).
    static func existingImportedIDs(accountID: String, in database: isolated BudgetDatabase, db: Database) throws -> Set<String> {
        guard try database.tableExists("transactions", db: db) else {
            return []
        }
        let columns = try database.columnSet(for: "transactions", db: db)
        guard let importedIDColumn = TransactionRowColumns.importedID(in: columns),
              let accountColumn = TransactionRowColumns.account(in: columns) else {
            return []
        }
        let values = try String.fetchAll(
            db,
            sql: """
                SELECT \(importedIDColumn)
                FROM transactions
                WHERE \(accountColumn) = ?
                  AND \(importedIDColumn) IS NOT NULL
                  AND \(database.predicateForLiveRows(columns: columns))
                """,
            arguments: [accountID]
        )
        return Set(values.compactMap(Self.normalizedImportedID))
    }

    static func validateImportedIDsAbsent(_ expected: ImportedIDAbsence?, in database: isolated BudgetDatabase, db: Database) throws {
        guard let expected, !expected.importedIDs.isEmpty else { return }
        let existing = try existingImportedIDs(accountID: expected.accountID, in: database, db: db)
        guard existing.isDisjoint(with: expected.importedIDs) else {
            throw LocalFirstError.importedTransactionConflict
        }
    }

    static func validateMatchedRowsUnchanged(_ expected: MatchedRowsUnchanged?, in database: isolated BudgetDatabase, db: Database) throws {
        guard let expected, !expected.reviewed.isEmpty else { return }
        let ids = expected.reviewed.map(\.id)
        var current: [String: BankSyncReconciliation.Existing] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            for row in try BankSyncMatchSQL.bankSyncExistingRows(
                accountID: expected.accountID,
                window: 0...99_999_999,
                idChunk: chunk,
                importedIDChunk: [],
                in: database,
                db: db
            ) {
                current[row.id] = row
            }
        }
        for reviewed in expected.reviewed where current[reviewed.id] != reviewed {
            throw LocalFirstError.importedTransactionConflict
        }
    }
}
