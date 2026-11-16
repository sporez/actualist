import Foundation
import GRDB

enum BankSyncMatchSQL {
    /// Live rows in the match window with `v_transactions` semantics: valid
    /// split children included, tombstones and invalid `is_child` rows
    /// without a parent excluded. The window bound is month-widened by the
    /// caller; the reconciler applies the exact ±7-day filter.
    /// With `ids`, only those rows (still scoped to the account and window) are
    /// read, in id chunks that stay under SQLite's bound-variable limit.
    static func bankSyncExistingRows(
        accountID: String,
        window: ClosedRange<Int>,
        ids: [String]? = nil,
        orImportedIDs: Set<String> = [],
        in database: isolated BudgetDatabase
    ) throws -> [BankSyncReconciliation.Existing] {
        if let ids, ids.isEmpty { return [] }
        let idChunks: [[String]?] = ids.map { all in
            stride(from: 0, to: all.count, by: 500).map { Array(all[$0..<min($0 + 500, all.count)]) }
        } ?? [nil]
        guard !orImportedIDs.isEmpty else {
            return try idChunks.flatMap { chunk in
                try bankSyncExistingRows(accountID: accountID, window: window, idChunk: chunk, importedIDChunk: [], in: database)
            }
        }
        // The exact `imported_id` tier is not date-bound, so rows carrying one
        // of these ids join the window; chunked to stay under SQLite's
        // bound-variable limit, then de-duplicated in first-seen order.
        let sortedIDs = orImportedIDs.sorted()
        let importedChunks = stride(from: 0, to: sortedIDs.count, by: 500).map {
            Array(sortedIDs[$0..<min($0 + 500, sortedIDs.count)])
        }
        var seen = Set<String>()
        return try idChunks.flatMap { chunk in
            try importedChunks.flatMap { importedChunk in
                try bankSyncExistingRows(
                    accountID: accountID, window: window, idChunk: chunk, importedIDChunk: importedChunk, in: database
                )
            }
        }.filter { seen.insert($0.id).inserted }
    }

    private static func bankSyncExistingRows(
        accountID: String,
        window: ClosedRange<Int>,
        idChunk: [String]?,
        importedIDChunk: [String],
        in database: isolated BudgetDatabase
    ) throws -> [BankSyncReconciliation.Existing] {
        try database.queue.read { db in
            try bankSyncExistingRows(
                accountID: accountID, window: window,
                idChunk: idChunk, importedIDChunk: importedIDChunk, in: database, db: db
            )
        }
    }

    static func bankSyncExistingRows(
        accountID: String,
        window: ClosedRange<Int>,
        idChunk: [String]?,
        importedIDChunk: [String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [BankSyncReconciliation.Existing] {
        guard try database.tableExists("transactions", db: db) else { return [] }
        let columns = try database.columnSet(for: "transactions", db: db)
        let split = TransactionSplitQueryExpressions(columns: columns)
        let financialIDColumn = TransactionRowColumns.importedID(in: columns)
        let importedPayeeColumn = TransactionRowColumns.importedPayee(in: columns)
        let transferIDColumn = TransactionRowColumns.transferID(in: columns)
        let financialIDSelect = financialIDColumn.map { "t.\($0)" } ?? "NULL"
        let importedPayeeSelect = importedPayeeColumn.map { "t.\($0)" } ?? "NULL"
        let transferIDSelect = transferIDColumn.map { "t.\($0)" } ?? "NULL"

        let importedIDScope = financialIDColumn.flatMap { column -> String? in
            importedIDChunk.isEmpty
                ? nil
                : "t.\(column) IN (\(Array(repeating: "?", count: importedIDChunk.count).joined(separator: ",")))"
        }
        let dateScope = importedIDScope.map {
            "(\(split.qualifiedDate) BETWEEN ? AND ? OR \($0))"
        } ?? "\(split.qualifiedDate) BETWEEN ? AND ?"
        let sql = """
            SELECT t.id AS id,
                   \(financialIDSelect) AS financial_id,
                   \(split.qualifiedDate) AS date,
                   \(split.qualifiedAmount) AS amount,
                   \(split.qualifiedPayee) AS payee,
                   \(split.qualifiedCategory) AS category,
                   \(split.qualifiedNotes) AS notes,
                   \(split.qualifiedCleared) AS cleared,
                   \(split.qualifiedReconciled) AS reconciled,
                   \(importedPayeeSelect) AS imported_payee,
                   \(split.qualifiedIsParent) AS is_parent,
                   \(split.qualifiedIsChild) AS is_child,
                   \(split.effectiveParentID) AS parent_id,
                   \(transferIDSelect) AS transfer_id,
                   \(split.qualifiedStartingBalance) AS starting_balance_flag,
                   \(split.qualifiedSortOrder) AS sort_order
            FROM transactions t
            \(split.parentJoin())
            WHERE \(split.qualifiedAccount) = ?
              AND \(dateScope)
              AND \(split.liveEffectivePredicate())
              \(idChunk.map { "AND t.id IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))" } ?? "")
            """
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([accountID, window.lowerBound, window.upperBound] as [any DatabaseValueConvertible])
                + StatementArguments(importedIDScope == nil ? [] : importedIDChunk)
                + StatementArguments(idChunk ?? [])
        ).compactMap { row in
            guard let id: String = row["id"],
                  let day: Int = row["date"] else {
                return nil
            }
            let isParent = (row["is_parent"] as Int? ?? 0) != 0
            let isChild = (row["is_child"] as Int? ?? 0) != 0
            return BankSyncReconciliation.Existing(
                id: id,
                financialID: row["financial_id"],
                dayID: String(day),
                amountMinorUnits: row["amount"] as Int? ?? 0,
                payeeID: row["payee"],
                categoryID: isParent ? nil : row["category"],
                notes: row["notes"],
                cleared: (row["cleared"] as Int? ?? 0) != 0,
                reconciled: (row["reconciled"] as Int? ?? 0) != 0,
                importedPayee: row["imported_payee"],
                isParent: isParent,
                isChild: isChild,
                parentID: isChild ? row["parent_id"] : nil,
                transferID: (row["transfer_id"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                isStartingBalance: (row["starting_balance_flag"] as Int? ?? 0) != 0,
                sortOrder: row["sort_order"] as Double? ?? 0
            )
        }
    }

    /// One matched row's update messages. Only fields that actually change
    /// from the current row are written; the parent's planned cleared value
    /// cascades onto its live children in the same commit.
    ///
    /// - Parameter clearsMissingImportIdentity: Write null over a stored
    ///   `imported_id` / `imported_payee` the update does not carry (CSV, as
    ///   upstream's `x || null`). Bank Sync never clears either.
    static func makeBankSyncMatchUpdateMessages(
        update: BankSyncReconciliation.MatchedUpdate,
        existing: BankSyncReconciliation.Existing,
        accountIsOffBudget: Bool = false,
        clearsMissingImportIdentity: Bool = false,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let columns = try database.columnSet(for: "transactions", db: db)
            var messages: [ActualSyncDecodedMessage] = []

            func appendIfChanged(_ column: String, _ newValue: LocalFirstSyncValue, changed: Bool) throws {
                guard changed else { return }
                messages.append(try builder.makeMessage(
                    dataset: "transactions", row: update.existingID, column: column, value: newValue
                ))
            }

            if let financialIDColumn = TransactionRowColumns.importedID(in: columns) {
                if let financialID = update.financialID {
                    try appendIfChanged(
                        financialIDColumn,
                        .string(financialID),
                        changed: financialID != existing.financialID
                    )
                } else if clearsMissingImportIdentity {
                    try appendIfChanged(financialIDColumn, .null, changed: existing.financialID != nil)
                }
            }
            let payeeColumn = try database.firstExistingColumn(TransactionRowColumns.payeeAliases, in: columns, table: "transactions")
            if let payeeID = update.payeeID {
                try appendIfChanged(payeeColumn, .string(payeeID), changed: payeeID != existing.payeeID)
            }
            // Bank Sync never manufactures a category on a transfer or off-budget row.
            if columns.contains("category"),
               let categoryID = update.categoryID,
               !existing.isTransfer,
               !accountIsOffBudget {
                try appendIfChanged("category", .string(categoryID), changed: categoryID != existing.categoryID)
            }
            if let importedPayeeColumn = TransactionRowColumns.importedPayee(in: columns) {
                if let importedPayee = update.importedPayee {
                    try appendIfChanged(
                        importedPayeeColumn,
                        .string(importedPayee),
                        changed: importedPayee != existing.importedPayee
                    )
                } else if clearsMissingImportIdentity {
                    try appendIfChanged(importedPayeeColumn, .null, changed: existing.importedPayee != nil)
                }
            }
            if columns.contains("notes"), let notes = update.notes {
                try appendIfChanged("notes", .string(notes), changed: notes != existing.notes)
            }
            if columns.contains("cleared") {
                try appendIfChanged("cleared", .bool(update.cleared), changed: update.cleared != existing.cleared)
            }
            if let dayID = update.dayID, let packed = Int64(dayID) {
                try appendIfChanged("date", .int(packed), changed: dayID != existing.dayID)
                for childID in update.dateChildIDs {
                    messages.append(try builder.makeMessage(
                        dataset: "transactions", row: childID, column: "date", value: .int(packed)
                    ))
                }
            }
            for childID in update.childIDs where columns.contains("cleared") {
                messages.append(try builder.makeMessage(
                    dataset: "transactions", row: childID, column: "cleared", value: .bool(update.cleared)
                ))
            }
            return messages
        }
    }

    /// A matched plain row that took a transfer payee becomes a transfer: the
    /// paired leg and the link (`transfer.ts` `onUpdate`), through the shared
    /// transfer writer. Empty when the payee is not a transfer payee or the row
    /// is already a transfer or a split parent.
    static func makeBankSyncTransferConversionMessages(
        update: BankSyncReconciliation.MatchedUpdate,
        existing: BankSyncReconciliation.Existing,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> (messages: [ActualSyncDecodedMessage], destinationAccountID: String?, pairedTransactionID: String?) {
        try database.queue.read { db in
            guard !existing.isTransfer, !existing.isParent, let payeeID = update.payeeID, payeeID != existing.payeeID,
                  try database.transferAccountID(ifPayee: payeeID, db: db) != nil else { return ([], nil, nil) }
            let columns = try TransactionRowColumns.resolve(in: database, db: db)
            guard var old = try database.loadTransactionRecord(id: update.existingID, columns: columns, db: db) else {
                return ([], nil, nil)
            }
            // The pair mirrors the row as updated: the update's category, notes and date.
            old.category = update.categoryID ?? old.category
            old.notes = update.notes ?? old.notes
            if let dayID = update.dayID {
                old.date = "\(dayID.prefix(4))-\(dayID.dropFirst(4).prefix(2))-\(dayID.suffix(2))"
            }
            var new = old
            new.payee = payeeID
            let result = try database.transferMessagesOnUpdate(old: old, new: new, columns: columns, db: db, builder: &builder)
            return (result.messages, result.accounts.first, result.transactions.first)
        }
    }
}
