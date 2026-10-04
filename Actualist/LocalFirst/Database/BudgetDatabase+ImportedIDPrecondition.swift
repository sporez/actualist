import Foundation
import GRDB

extension BudgetDatabase {
    /// `imported_id` values an import is about to insert on one account.
    /// The commit transaction re-checks them, because a remote row can land
    /// between the import's read and its write.
    struct ImportedIDAbsence: Sendable {
        let accountID: String
        let importedIDs: Set<String>

        init(accountID: String, importedIDs: some Sequence<String>) {
            self.accountID = accountID
            self.importedIDs = Set(importedIDs.compactMap(BudgetDatabase.normalizedImportedID))
        }
    }

    static func normalizedImportedID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Live imported ids on an account, trimmed and lowercased.
    func existingImportedIDs(accountID: String, db: Database) throws -> Set<String> {
        guard try tableExists("transactions", db: db) else {
            return []
        }
        let columns = try columnSet(for: "transactions", db: db)
        guard let importedIDColumn = ["financial_id", "imported_id"].first(where: columns.contains),
              let accountColumn = ["acct", "account"].first(where: columns.contains) else {
            return []
        }
        let values = try String.fetchAll(
            db,
            sql: """
                SELECT \(importedIDColumn)
                FROM transactions
                WHERE \(accountColumn) = ?
                  AND \(importedIDColumn) IS NOT NULL
                  AND \(predicateForLiveRows(columns: columns))
                """,
            arguments: [accountID]
        )
        return Set(values.compactMap(Self.normalizedImportedID))
    }

    func validateImportedIDsAbsent(_ expected: ImportedIDAbsence?, db: Database) throws {
        guard let expected, !expected.importedIDs.isEmpty else { return }
        let existing = try existingImportedIDs(accountID: expected.accountID, db: db)
        guard existing.isDisjoint(with: expected.importedIDs) else {
            throw LocalFirstError.importedTransactionConflict
        }
    }
}
