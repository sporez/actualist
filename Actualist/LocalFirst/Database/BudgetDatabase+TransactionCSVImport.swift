import Foundation
import GRDB

extension BudgetDatabase {
    /// Legacy matcher read; deleted with the CSV-only matcher (main-to-dev 3.5).
    /// Existing live rows in the importing account, reduced for reconcile
    /// matching. Child split rows are excluded; a split family matches through
    /// its parent. Sorted by date so fuzzy candidates carry a stable order.
    /// Only rows inside `scope`'s date window, or carrying one of its imported
    /// IDs, are returned; the imported-ID side is not date-bound.
    func fetchTransactionCSVImportCandidates(
        accountID: String,
        scope: TransactionCSVImportMatcher.CandidateScope
    ) throws -> [TransactionCSVImportCandidate] {
        // SQLite bounds the number of bound variables; past this, any row that
        // carries an imported ID is a superset of the requested IDs.
        let maxBoundImportedIDs = 500
        return try queue.read { db in
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
            let isParentColumn = ["is_parent", "isParent"].first(where: columns.contains)
            let transferColumn = ["transferred_id", "transfer_id"].first(where: columns.contains)
            let accountOffBudget = try accountOffBudget(accountID, db: db)
            let isChildFilter = isChildColumn.map { "AND (\($0) IS NULL OR \($0) = 0)" } ?? ""
            let clearedSelect = columns.contains("cleared")
                ? "cleared, (cleared IS NULL) AS cleared_is_null"
                : "NULL AS cleared, 1 AS cleared_is_null"
            // The date window and the imported-ID side are alternatives.
            var scopeTerms: [String] = []
            var arguments: StatementArguments = [accountID]
            if let window = scope.dateWindow {
                scopeTerms.append("\(normalizedDateExpression("date")) BETWEEN ? AND ?")
                arguments += StatementArguments([window.from, window.to])
            }
            if let importedIDColumn, !scope.importedIDs.isEmpty {
                if scope.importedIDs.count > maxBoundImportedIDs {
                    scopeTerms.append("(\(importedIDColumn) IS NOT NULL AND \(importedIDColumn) <> '')")
                } else {
                    let ids = scope.importedIDs.sorted()
                    scopeTerms.append("\(importedIDColumn) IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))")
                    arguments += StatementArguments(ids)
                }
            }
            guard !scopeTerms.isEmpty else {
                return []
            }
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
                       \(importedPayeeColumn ?? "NULL") AS imported_payee,
                       \(isParentColumn ?? "0") AS is_parent,
                       \(transferColumn ?? "NULL") AS transfer_id
                FROM transactions
                WHERE \(accountColumn) = ?
                  \(isChildFilter)
                  AND \(predicateForLiveRows(columns: columns))
                  AND (\(scopeTerms.joined(separator: " OR ")))
                ORDER BY date, id
                """
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
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
                    reconciled: flexibleBool(row["reconciled"]),
                    isParent: flexibleBool(row["is_parent"]),
                    transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                    accountOffBudget: accountOffBudget
                )
            }
        }
    }

    /// One matched row decided at review time, with its CSV line for error
    /// reporting. `existing` is the stored row as the review saw it.
    struct TransactionCSVImportMatch: Sendable {
        let line: Int
        let update: BankSyncReconciliation.MatchedUpdate
        let existing: BankSyncReconciliation.Existing
    }

    /// Single atomic commit for a CSV import. The messages come from the shared
    /// import reconcile step; the preconditions run in the same write
    /// transaction, so a match that changed after review, or a row someone else
    /// imported with the same `imported_id`, rejects the whole import and
    /// writes nothing.
    func commitTransactionCSVImport(
        accountID: String,
        messages: [ActualSyncDecodedMessage],
        matches: [TransactionCSVImportMatch],
        expectedAbsentImportedIDs: ImportedIDAbsence,
        now: Date = Date()
    ) throws {
        try Task.checkCancellation()
        _ = try commitLocalPlan(now: now) { db in
            try Task.checkCancellation()
            let columns = try columnSet(for: "transactions", db: db)
            for match in matches {
                try validateTransactionCSVImportMatch(match, accountID: accountID, columns: columns, db: db)
            }
            try validateImportedIDsAbsent(expectedAbsentImportedIDs, db: db)
            return LocalCommitPlan(drafts: messages, action: nil, outcome: ())
        }
    }

    /// The row must still be live, in the importing account and not
    /// reconciled, and every field the update writes must still hold the value
    /// the review saw (the fill semantics the review showed).
    private func validateTransactionCSVImportMatch(
        _ match: TransactionCSVImportMatch,
        accountID: String,
        columns: Set<String>,
        db: Database
    ) throws {
        let changed = TransactionCSVImportError.matchChanged(line: match.line)
        let update = match.update
        let existing = match.existing
        let accountColumn = ["acct", "account"].first(where: columns.contains)
        let payeeColumn = ["description", "payee"].first(where: columns.contains)
        guard let accountColumn,
              let live = try Row.fetchOne(
                  db,
                  sql: """
                      SELECT \(accountColumn) AS account,
                             \(payeeColumn ?? "NULL") AS payee,
                             \(columns.contains("category") ? "category" : "NULL") AS category,
                             \(columns.contains("notes") ? "notes" : "NULL") AS notes,
                             \(columns.contains("cleared") ? "cleared" : "NULL") AS cleared,
                             \(columns.contains("reconciled") ? "reconciled" : "NULL") AS reconciled
                      FROM transactions
                      WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                      """,
                  arguments: [update.existingID]
              ),
              (live["account"] as String?) == accountID,
              !flexibleBool(live["reconciled"]) else {
            throw changed
        }
        func stored(_ column: String) -> String? {
            let value: String? = live[column]
            return value?.isEmpty == false ? value : nil
        }
        func reviewed(_ value: String?) -> String? {
            value?.isEmpty == false ? value : nil
        }
        if update.payeeID != existing.payeeID, stored("payee") != reviewed(existing.payeeID) { throw changed }
        if update.categoryID != existing.categoryID, stored("category") != reviewed(existing.categoryID) { throw changed }
        if update.notes != existing.notes, stored("notes") != reviewed(existing.notes) { throw changed }
        if update.cleared != existing.cleared, flexibleBool(live["cleared"]) != existing.cleared { throw changed }
        // The cleared cascade only reaches children that are still live.
        if !update.childIDs.isEmpty {
            let split = transactionSplitQueryExpressions(columns: columns, tableAlias: "transactions")
            let liveChildren = try Set(String.fetchAll(
                db,
                sql: """
                    SELECT id FROM transactions
                    WHERE \(split.parentID) = ? AND (\(split.isChild)) = 1
                      AND \(predicateForLiveRows(columns: columns))
                    """,
                arguments: [update.existingID]
            ))
            guard Set(update.childIDs).isSubset(of: liveChildren) else { throw changed }
        }
    }
}
