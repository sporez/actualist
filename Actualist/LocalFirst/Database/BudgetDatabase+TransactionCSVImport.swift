import Foundation
import GRDB

extension BudgetDatabase {
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
