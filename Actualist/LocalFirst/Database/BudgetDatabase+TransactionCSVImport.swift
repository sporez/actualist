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
            let isParentColumn = ["is_parent", "isParent"].first(where: columns.contains)
            let transferColumn = ["transferred_id", "transfer_id"].first(where: columns.contains)
            let accountOffBudget = try accountOffBudget(accountID, db: db)
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
                       \(importedPayeeColumn ?? "NULL") AS imported_payee,
                       \(isParentColumn ?? "0") AS is_parent,
                       \(transferColumn ?? "NULL") AS transfer_id
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
                    reconciled: flexibleBool(row["reconciled"]),
                    isParent: flexibleBool(row["is_parent"]),
                    transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                    accountOffBudget: accountOffBudget
                )
            }
        }
    }

    /// One matched-row update decided at review time, with its CSV line for
    /// error reporting.
    struct TransactionCSVImportUpdate: Sendable {
        let line: Int
        let plan: TransactionCSVImportUpdatePlan
    }

    /// Single atomic commit for a CSV import. Every update is validated and
    /// its messages are built against the live row inside the same write
    /// transaction, so a match that changed after review rejects the whole
    /// import and writes nothing. Insert messages were built earlier; they
    /// do not depend on existing rows.
    func commitTransactionCSVImport(
        accountID: String,
        updates: [TransactionCSVImportUpdate],
        insertMessages: [ActualSyncDecodedMessage],
        builder: inout LocalFirstSyncMessageBuilder,
        now: Date = Date()
    ) throws {
        try Task.checkCancellation()
        try sessionWritesAllowed.withLock { allowed in
            guard allowed else { throw LocalFirstError.budgetNotOpened }
            try Task.checkCancellation()
            _ = try commitLocalPlan(now: now) { db in
                try Task.checkCancellation()
                var messages = insertMessages
                let columns = try columnSet(for: "transactions", db: db)
                for update in updates {
                    let updateMessages = try transactionCSVImportUpdateMessages(
                        update,
                        accountID: accountID,
                        columns: columns,
                        db: db,
                        builder: &builder
                    )
                    guard !updateMessages.isEmpty else {
                        throw LocalFirstError.invalidLocalWrite("missing transaction")
                    }
                    messages += updateMessages
                }
                return LocalCommitPlan(drafts: messages, action: nil, outcome: ())
            }
        }
    }

    /// Validates a matched row against its live state, then emits field-level
    /// set messages for the columns the plan fills. The row must still be
    /// live, in the importing account, not reconciled, and every field the
    /// plan fills must still be empty (the fill semantics the review showed).
    private func transactionCSVImportUpdateMessages(
        _ update: TransactionCSVImportUpdate,
        accountID: String,
        columns: Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let plan = update.plan
        let changed = TransactionCSVImportError.matchChanged(line: update.line)
        let accountColumn = ["acct", "account"].first(where: columns.contains)
        let split = transactionSplitQueryExpressions(columns: columns, tableAlias: "transactions")
        let transferColumn = ["transferred_id", "transfer_id"].first(where: columns.contains)
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
                             \(columns.contains("reconciled") ? "reconciled" : "NULL") AS reconciled,
                             \(split.qualifiedIsParent) AS is_parent,
                             \(transferColumn ?? "NULL") AS transfer_id
                      FROM transactions
                      WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                      """,
                  arguments: [plan.existingTransactionID]
              ),
              (live["account"] as String?) == accountID,
              !flexibleBool(live["reconciled"]) else {
            throw changed
        }
        func isEmpty(_ column: String) -> Bool {
            ((live[column] as String?) ?? "").isEmpty
        }
        if plan.payeeID != nil, !isEmpty("payee") { throw changed }
        if plan.categoryID != nil {
            let offBudget = try accountOffBudget(accountID, db: db)
            let forbidden = flexibleBool(live["is_parent"]) || !isEmpty("transfer_id") || offBudget
            if forbidden || !isEmpty("category") { throw changed }
        }
        if plan.notes != nil, !isEmpty("notes") { throw changed }
        if let cleared = plan.cleared, flexibleBool(live["cleared"]) == cleared { throw changed }

        var messages: [ActualSyncDecodedMessage] = []
        func append(_ column: String, _ value: LocalFirstSyncValue) throws {
            messages.append(try builder.makeMessage(
                dataset: "transactions",
                row: plan.existingTransactionID,
                column: column,
                value: value
            ))
        }
        if let payeeID = plan.payeeID, let payeeColumn {
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
            // Upstream copies a matched parent's cleared onto its live
            // children (`reconcileTransactions`, sync.ts 721-735).
            if flexibleBool(live["is_parent"]) {
                let childIDs = try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM transactions
                        WHERE \(split.parentID) = ? AND (\(split.isChild)) = 1
                          AND \(predicateForLiveRows(columns: columns))
                        """,
                    arguments: [plan.existingTransactionID]
                )
                for childID in childIDs {
                    messages.append(try builder.makeMessage(
                        dataset: "transactions",
                        row: childID,
                        column: "cleared",
                        value: .bool(cleared)
                    ))
                }
            }
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
