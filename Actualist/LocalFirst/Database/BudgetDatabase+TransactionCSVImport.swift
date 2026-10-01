import Foundation
import GRDB

extension BudgetDatabase {

    /// Existing live rows in the importing account, reduced for reconcile
    /// matching. Child split rows are excluded; a split family matches through
    /// its parent. Sorted by date so fuzzy candidates carry a stable order.
    func fetchTransactionCSVImportCandidates(accountID: String) throws -> [TransactionCSVImportCandidate] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return []
            }
            let columns = try columnSet(for: "transactions", db: db)
            guard let accountColumn = ["acct", "account"].first(where: columns.contains),
                  columns.contains("date"),
                  columns.contains("amount") else {
                return []
            }
            let payeeColumn = ["description", "payee"].first(where: columns.contains)
            let importedIDColumn = ["financial_id", "imported_id"].first(where: columns.contains)
            let importedPayeeColumn = ["imported_description", "imported_payee"].first(where: columns.contains)
            let isChildColumn = ["is_child", "isChild"].first(where: columns.contains)
            let isChildFilter = isChildColumn.map { "AND (\($0) IS NULL OR \($0) = 0)" } ?? ""
            let clearedSelect = columns.contains("cleared")
                ? "cleared, (cleared IS NULL) AS cleared_is_null"
                : "NULL AS cleared, 1 AS cleared_is_null"
            let sql = """
                SELECT id,
                       \(normalizedDateExpression("date")) AS date_text,
                       amount,
                       \(payeeColumn ?? "NULL") AS payee_id,
                       category,
                       \(columns.contains("notes") ? "notes" : "NULL") AS notes,
                       \(clearedSelect),
                       \(columns.contains("reconciled") ? "reconciled" : "NULL") AS reconciled,
                       \(importedIDColumn ?? "NULL") AS imported_id,
                       \(importedPayeeColumn ?? "NULL") AS imported_payee
                FROM transactions
                WHERE \(accountColumn) = ?
                  \(isChildFilter)
                  AND \(predicateForLiveRows(columns: columns))
                ORDER BY date, id
                """
            return try Row.fetchAll(db, sql: sql, arguments: [accountID]).compactMap { row in
                let amount: Int? = row["amount"]
                guard let amount else {
                    return nil
                }
                let importedID: String? = row["imported_id"]
                return TransactionCSVImportCandidate(
                    id: row["id"] ?? "",
                    importedID: importedID.flatMap { $0.isEmpty ? nil : $0 },
                    payeeID: row["payee_id"],
                    categoryID: row["category"],
                    notes: row["notes"],
                    // A NULL (or absent) cleared column carries no cleared
                    // information and must never fill a matched row.
                    cleared: (row["cleared_is_null"] ?? 1) == 1 ? nil : flexibleBool(row["cleared"]),
                    importedPayee: row["imported_payee"],
                    amountMinorUnits: amount,
                    dateText: row["date_text"] ?? "",
                    reconciled: flexibleBool(row["reconciled"])
                )
            }
        }
    }

    /// Field-level set messages for a matched-row update. The matcher has
    /// already decided the changing fields (fill semantics); this only emits
    /// messages for the columns the row carries. The caller commits them
    /// through the shared `commitLocalSyncMessagesAndEnqueue` plan — this is
    /// not a second write engine.
    func transactionCSVImportUpdateMessages(
        plan: TransactionCSVImportUpdatePlan,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            guard try tableExists("transactions", db: db) else {
                return []
            }
            let columns = try columnSet(for: "transactions", db: db)
            if columns.contains("reconciled") {
                let reconciled = try Int.fetchOne(
                    db,
                    sql: "SELECT reconciled FROM transactions WHERE id = ?",
                    arguments: [plan.existingTransactionID]
                )
                // A matched row can become reconciled between review and
                // submit; the review already skips reconciled rows, so a
                // stale plan must not write into one.
                if (reconciled ?? 0) != 0 {
                    throw LocalFirstError.invalidLocalWrite("transaction is reconciled")
                }
            }
            var messages: [ActualSyncDecodedMessage] = []
            func append(_ column: String, _ value: LocalFirstSyncValue) throws {
                messages.append(try builder.makeMessage(
                    dataset: "transactions",
                    row: plan.existingTransactionID,
                    column: column,
                    value: value
                ))
            }
            if let payeeID = plan.payeeID,
               let payeeColumn = ["description", "payee"].first(where: columns.contains) {
                try append(payeeColumn, .string(payeeID))
            }
            if let categoryID = plan.categoryID, columns.contains("category") {
                try append("category", .string(categoryID))
            }
            if let notes = plan.notes, columns.contains("notes") {
                try append("notes", .string(notes))
            }
            if let cleared = plan.cleared, columns.contains("cleared") {
                try append("cleared", .bool(cleared))
            }
            if let importedPayee = plan.importedPayee,
               let importedPayeeColumn = ["imported_description", "imported_payee"].first(where: columns.contains) {
                try append(importedPayeeColumn, .string(importedPayee))
            }
            if let importedID = plan.importedID, !importedID.isEmpty,
               let importedIDColumn = ["financial_id", "imported_id"].first(where: columns.contains) {
                try append(importedIDColumn, .string(importedID))
            }
            return messages
        }
    }
}
