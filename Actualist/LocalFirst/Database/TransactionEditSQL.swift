import Foundation
import GRDB

extension BudgetDatabase.TransactionWriteResult {
    /// The listed rows whose category this write sets to a value. An unchanged
    /// category emits no message and a cleared one emits null, so neither
    /// qualifies (loot-core: `updated.filter(update => update.category)`).
    func categoryAssignedIDs(among rowIDs: Set<String>) -> Set<String> {
        Set(messages.compactMap { message in
            message.dataset == "transactions" && message.column == "category"
                && message.serializedValue != LocalFirstSyncValue.null.serialized
                && rowIDs.contains(message.row) ? message.row : nil
        })
    }
}

/// What an edit of a simple (non-split) row changes, measured against the
/// caller's loaded baseline. Mirrors loot-core `diffItems`: only differing
/// fields are written, so a stale editor cannot overwrite a remote edit to a
/// field it did not touch.
struct SimpleRowChange {
    let baseline: ActualTransaction
    let draft: TransactionDraft
    let payeeID: String?
    let category: String?
    let dateValue: Int

    var accountChanged: Bool { draft.accountID != baseline.account }
    var payeeChanged: Bool { payeeID != baseline.payee }
    var amountChanged: Bool { draft.amountMinorUnits != (baseline.amount ?? 0) }
    /// A stored NULL and an empty field are the same note: Actual's editor writes notes only
    /// when the field's value differs from the transaction's (`notes ?? ''`).
    var notesChanged: Bool { (draft.notes ?? "") != (baseline.notes ?? "") }
    var categoryChanged: Bool { category != baseline.category }

    /// Dates compare as digits (baseline `2026-03-05` against `20260305`).
    var dateChanged: Bool { PackedDate.packed(fromISO: baseline.date) != dateValue }
}

enum TransactionEditSQL {
    /// Reads the existing row and its pair through `db`, so an update built in its
    /// own write transaction sees the family and transfer state at commit time.
    /// A simple row writes only the cells that differ between `baseline` (what the
    /// caller loaded; the in-transaction row when nil) and the draft, as loot-core's
    /// `diffItems` does. A full write would overwrite remote edits and resurrect a
    /// row deleted elsewhere (`tombstone=false`).
    static func updateTransactionMessages(
        transactionID: String,
        draft: TransactionDraft,
        payeeID: String?,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
        baseline: ActualTransaction? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.TransactionWriteResult {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }

        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        guard try database.rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        try ReconciledMutationReviewSQL.validateReconciledMutationAuthorization(
            transactionID: trimmedTransactionID,
            authorization: reconciliationAuthorization,
            columns: columns,
            in: database,
            db: db
        )
        if try database.tableExists("accounts", db: db),
           try !database.liveRowExists(table: "accounts", rowID: draft.accountID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }

        let existing = try existingTransactionState(id: trimmedTransactionID, columns: columns, in: database, db: db)
        let isFamilyWrite = existing.isParent || existing.isChild || draft.isSplit
        if !isFamilyWrite {
            guard draft.amountMinorUnits != 0 else {
                throw LocalFirstError.invalidLocalWrite("missing amount")
            }
        } else {
            return try SplitFamilySQL.splitFamilyUpdateMessages(
                transactionID: trimmedTransactionID,
                draft: draft,
                payeeID: payeeID,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }
        // A transfer needs its transfer payee; any other row may have no payee, as in Actual.
        if draft.isTransfer, payeeID == nil {
            throw LocalFirstError.invalidLocalWrite("missing payee")
        }
        let dateValue = try BudgetDatabase.actualDateValue(draft.date)
        guard let baselineRow = try baseline ?? TransactionReadSQL.fetchTransaction(id: trimmedTransactionID, in: database, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        let isTransferDraft = draft.isTransfer
        let mainCategory: String?
        let pairedCategory: String?
        if isTransferDraft, let payeeID {
            // Put the category on the budget side of a cross-budget transfer.
            let destination = try TransferSQL.transferDestinationAccountID(payeeID: payeeID, in: database, db: db)
            let categories = try TransferSQL.transferCategories(
                draft: draft,
                sourceAccountID: draft.accountID,
                destinationAccountID: destination,
                in: database,
                db: db
            )
            mainCategory = categories.source
            pairedCategory = categories.destination
        } else if draft.accountID != baselineRow.account,
                  try AccountSQL.accountOffBudget(draft.accountID, in: database, db: db) {
            // loot-core `batchUpdateTransactions`: moving a row to an off-budget
            // account clears its category.
            mainCategory = nil
            pairedCategory = nil
        } else {
            mainCategory = draft.categoryID
            pairedCategory = nil
        }
        if let mainCategory,
           try database.tableExists("categories", db: db),
           try !database.liveRowExists(table: "categories", rowID: mainCategory, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        var messages: [ActualSyncDecodedMessage] = []
        var affectedAccounts: Set<String> = [existing.account, draft.accountID]
        var affectedTransactions: Set<String> = [trimmedTransactionID]

        let change = SimpleRowChange(
            baseline: baselineRow,
            draft: draft,
            payeeID: payeeID,
            category: mainCategory,
            dateValue: dateValue
        )
        messages += try simpleRowDiffMessages(
            transactionID: trimmedTransactionID,
            change: change,
            columns: columns,
            builder: &builder
        )

        // Keep transfer transitions aligned with loot-core's onUpdate.
        messages += try transferTransitionMessages(
            mainID: trimmedTransactionID,
            draft: draft,
            payeeID: payeeID,
            dateValue: dateValue,
            pairedCategory: pairedCategory,
            change: change,
            existing: existing,
            columns: columns,
            affectedAccounts: &affectedAccounts,
            affectedTransactions: &affectedTransactions,
            builder: &builder,
            in: database,
            db: db
        )

        return BudgetDatabase.TransactionWriteResult(
            messages: messages,
            affectedAccountIDs: Array(affectedAccounts),
            affectedTransactionIDs: Array(affectedTransactions)
        )
    }

    static func existingTransactionState(
        id: String,
        columns: TransactionRowColumns,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.ExistingTransactionState {
        let account = try String.fetchOne(
            db,
            sql: "SELECT \(columns.account) FROM transactions WHERE id = ?",
            arguments: [id]
        ) ?? ""
        var isParent = false
        if let isParentColumn = columns.isParent,
           let value = try Int.fetchOne(
            db,
            sql: "SELECT \(isParentColumn) FROM transactions WHERE id = ?",
            arguments: [id]
           ) {
            isParent = value != 0
        }
        var isChild = false
        if let isChildColumn = columns.isChild,
           let value = try Int.fetchOne(
            db,
            sql: "SELECT \(isChildColumn) FROM transactions WHERE id = ?",
            arguments: [id]
           ) {
            isChild = value != 0
        }
        var parentID: String?
        if columns.hasParentID {
            parentID = try String.fetchOne(
                db,
                sql: "SELECT parent_id FROM transactions WHERE id = ?",
                arguments: [id]
            ).flatMap { $0.isEmpty ? nil : $0 }
        }
        var transferID: String?
        if let transferColumn = columns.transferID {
            transferID = try String.fetchOne(
                db,
                sql: "SELECT \(transferColumn) FROM transactions WHERE id = ?",
                arguments: [id]
            ).flatMap { $0.isEmpty ? nil : $0 }
        }
        let childIDs = columns.hasParentID
            ? try String.fetchAll(
                db,
                sql: "SELECT id FROM transactions WHERE parent_id = ? AND \(database.predicateForLiveRows(columns: columns.all))",
                arguments: [id]
            )
            : []

        var pairedAccount: String?
        var pairedIsChild = false
        if let pairedID = transferID {
            pairedAccount = try String.fetchOne(
                db,
                sql: "SELECT \(columns.account) FROM transactions WHERE id = ?",
                arguments: [pairedID]
            )
            if let isChildColumn = columns.isChild,
               let value = try Int.fetchOne(
                db,
                sql: "SELECT \(isChildColumn) FROM transactions WHERE id = ?",
                arguments: [pairedID]
               ) {
                pairedIsChild = value != 0
            }
        }

        return BudgetDatabase.ExistingTransactionState(
            account: account,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            transferID: transferID,
            childIDs: childIDs,
            pairedAccount: pairedAccount,
            pairedIsChild: pairedIsChild
        )
    }

    private static func transferTransitionMessages(
        mainID: String,
        draft: TransactionDraft,
        payeeID: String?,
        dateValue: Int,
        pairedCategory: String?,
        change: SimpleRowChange,
        existing: BudgetDatabase.ExistingTransactionState,
        columns: TransactionRowColumns,
        affectedAccounts: inout Set<String>,
        affectedTransactions: inout Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        // Split parents cannot be transfers.
        let nowTransfer = draft.isTransfer && !draft.isSplit
        var messages: [ActualSyncDecodedMessage] = []

        if nowTransfer, let payeeID {
            guard let transferColumn = columns.transferID else {
                throw LocalFirstError.schemaUnavailable("missing column transactions.transferred_id")
            }
            let destination = try TransferSQL.transferDestinationAccountID(payeeID: payeeID, in: database, db: db)
            let fromPayeeID = try TransferSQL.transferPayeeID(forAccount: draft.accountID, in: database, db: db)
            affectedAccounts.insert(destination)
            if let oldPaired = existing.pairedAccount {
                affectedAccounts.insert(oldPaired)
            }

            if let pairedID = existing.transferID {
                // loot-core leaves the paired row's date and cleared state unchanged.
                // Unlike loot-core, which rewrites the whole pair, only the legs'
                // cells whose source value changed are written (plan D7h).
                affectedTransactions.insert(pairedID)
                if change.payeeChanged {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.account, value: .string(destination)))
                }
                if change.accountChanged {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .string(fromPayeeID)))
                }
                if columns.hasNotes, change.notesChanged {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "notes", value: draft.notes.map(LocalFirstSyncValue.string) ?? .null))
                }
                if change.amountChanged {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "amount", value: .int(Int64(-draft.amountMinorUnits))))
                }
                if change.categoryChanged || change.accountChanged || change.payeeChanged {
                    let sourceOffBudget = try AccountSQL.accountOffBudget(draft.accountID, in: database, db: db)
                    let destinationOffBudget = try AccountSQL.accountOffBudget(destination, in: database, db: db)
                    if sourceOffBudget == destinationOffBudget || destinationOffBudget {
                        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "category", value: .null))
                    } else if let pairedCategory {
                        // The off-budget editor may not have loaded the paired row's category.
                        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "category", value: .string(pairedCategory)))
                    }
                }
            } else {
                let pairedID = UUID().uuidString
                affectedTransactions.insert(pairedID)
                messages += try columns.rowMessages(
                    rowID: pairedID,
                    accountID: destination,
                    dateValue: dateValue,
                    amountMinorUnits: -draft.amountMinorUnits,
                    payeeID: fromPayeeID,
                    categoryID: pairedCategory,
                    notes: draft.counterpartNotes,
                    cleared: false,
                    isParent: false,
                    parentID: nil,
                    isChild: false,
                    transferID: mainID,
                    sortOrder: nil,
                    builder: &builder,
                    cells: .snapshot
                )
                messages.append(try builder.makeMessage(dataset: "transactions", row: mainID, column: transferColumn, value: .string(pairedID)))
            }
        } else if let pairedID = existing.transferID, let transferColumn = columns.transferID {
            affectedTransactions.insert(pairedID)
            if let oldPaired = existing.pairedAccount {
                affectedAccounts.insert(oldPaired)
            }
            if existing.pairedIsChild {
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: transferColumn, value: .null))
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .null))
            } else if columns.hasTombstone {
                messages.append(try builder.tombstone(dataset: "transactions", row: pairedID))
            }
            messages.append(try builder.makeMessage(dataset: "transactions", row: mainID, column: transferColumn, value: .null))
        }

        return messages
    }

    /// `allowsZeroAmount` is for import inserts only (`ImportReconcileSteps.importReconcileWrites`);
    /// an entered or edited transaction needs an amount.
    static func validateSimpleTransactionDraft(_ draft: TransactionDraft, allowsZeroAmount: Bool = false) throws {
        guard !draft.isSplit else {
            throw LocalFirstError.unsupportedSplitWrite
        }
        guard !draft.isTransfer else {
            throw LocalFirstError.unsupportedTransferWrite
        }
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard allowsZeroAmount || draft.amountMinorUnits != 0 else {
            throw LocalFirstError.invalidLocalWrite("missing amount")
        }
    }

    /// The main row's changed cells. `isParent`, `parent_id`, `isChild`,
    /// `tombstone` and `error` are never written here: they are copied from the
    /// baseline so `messagesForChangedFields` sees no difference.
    private static func simpleRowDiffMessages(
        transactionID: String,
        change: SimpleRowChange,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let baseline = change.baseline
        let old = SplitTransactionRecord(
            id: transactionID,
            amount: baseline.amount ?? 0,
            account: baseline.account,
            date: baseline.date,
            category: baseline.category,
            payee: baseline.payee,
            notes: baseline.notes,
            cleared: baseline.cleared?.boolValue ?? false,
            reconciled: baseline.reconciled
        )
        var new = old
        new.account = change.draft.accountID
        new.amount = change.draft.amountMinorUnits
        new.payee = change.payeeID
        new.category = change.category
        new.notes = change.draft.notes
        new.cleared = change.draft.cleared
        new.reconciled = change.draft.reconciled
        if change.dateChanged {
            new.date = PackedDate.iso(change.dateValue)
        }
        var messages = try SplitFamilySQL.messagesForChangedFields(from: old, to: new, columns: columns, builder: &builder)
        if let scheduleID = change.draft.scheduleID, columns.hasSchedule, scheduleID != baseline.schedule {
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "schedule",
                    value: .string(scheduleID)
                )
            )
        }
        return messages
    }

    /// Validates and builds from the live row read through `db`, so a categorize
    /// built inside its write transaction sees a remote split or transfer change.
    static func categorizeTransactionMessages(
        transactionID: String,
        categoryID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        let transactionColumns = try database.requiredColumns(
            table: "transactions",
            required: ["category"],
            db: db
        )
        guard try database.liveRowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        let payeeColumn = try database.firstExistingColumn(TransactionRowColumns.payeeAliases, in: transactionColumns, table: "transactions")
        try validateCategorizationTarget(
            transactionID: trimmedTransactionID,
            columns: transactionColumns,
            payeeColumn: payeeColumn,
            in: database,
            db: db
        )
        // Same fail-closed guard as edit and delete, evaluated on the rows of
        // this write transaction (the row, its split family, its transfer pair).
        try ReconciledMutationReviewSQL.validateReconciledMutationAuthorization(
            transactionID: trimmedTransactionID,
            authorization: reconciliationAuthorization,
            columns: try TransactionRowColumns.resolve(in: database, db: db),
            in: database,
            db: db
        )
        if try database.tableExists("categories", db: db),
           try !database.liveRowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return [
            try builder.makeMessage(
                dataset: "transactions",
                row: trimmedTransactionID,
                column: "category",
                value: .string(trimmedCategoryID)
            )
        ]
    }

    /// Loads the family and transfer pair through `db`, so a delete built in its
    /// own write transaction tombstones the rows as they are when it commits.
    static func deleteTransactionMessages(
        transactionID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetDatabase.TransactionWriteResult {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        let columns = try TransactionRowColumns.resolve(in: database, db: db)
        guard columns.hasTombstone else {
            throw LocalFirstError.invalidLocalWrite("missing column transactions.tombstone")
        }
        guard try database.rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        try ReconciledMutationReviewSQL.validateReconciledMutationAuthorization(
            transactionID: trimmedTransactionID,
            authorization: reconciliationAuthorization,
            columns: columns,
            in: database,
            db: db
        )

        let existing = try existingTransactionState(id: trimmedTransactionID, columns: columns, in: database, db: db)
        if existing.isParent || existing.isChild {
            return try SplitFamilySQL.deleteSplitFamilyMessages(
                transactionID: trimmedTransactionID,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }
        let pair = existing.transferID.flatMap { pairedID in
            columns.transferID == nil
                ? nil
                : PlainTransactionDeletePair(
                    id: pairedID,
                    accountID: existing.pairedAccount,
                    isChild: existing.pairedIsChild
                )
        }
        return try TransactionBatchDeleteSQL.plainTransactionDeleteWrite(
            transactionID: trimmedTransactionID,
            accountID: existing.account,
            transferID: existing.transferID,
            pair: pair,
            columns: columns,
            builder: &builder
        )
    }

    static func validateCategorizationTarget(
        transactionID: String,
        columns: Set<String>,
        payeeColumn: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws {
        let isParentColumn = database.column(
            "is_parent",
            fallback: database.column("isParent", fallback: "0", columns: columns),
            columns: columns
        )
        if let isParent = try Int.fetchOne(
            db,
            sql: "SELECT \(isParentColumn) FROM transactions WHERE id = ?",
            arguments: [transactionID]
        ), isParent != 0 {
            throw LocalFirstError.unsupportedSplitWrite
        }
        guard try database.tableExists("payees", db: db),
              let payeeID = try String.fetchOne(
            db,
            sql: "SELECT \(payeeColumn) FROM transactions WHERE id = ?",
            arguments: [transactionID]
              ) else {
            return
        }

        let payeeColumns = try database.columnSet(for: "payees", db: db)
        let transferColumn = database.column(
            "transfer_acct",
            fallback: database.column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL",
              let destinationAccountID = try String.fetchOne(
                db,
                sql: "SELECT \(transferColumn) FROM payees WHERE id = ?",
                arguments: [payeeID]
              ),
              !destinationAccountID.isEmpty else {
            return
        }

        guard let sourceAccountID = try String.fetchOne(
            db,
            sql: "SELECT \(database.column("acct", fallback: "account", columns: columns)) FROM transactions WHERE id = ?",
            arguments: [transactionID]
        ) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction account")
        }
        let sourceOffBudget = try AccountSQL.accountOffBudget(sourceAccountID, in: database, db: db)
        let destinationOffBudget = try AccountSQL.accountOffBudget(destinationAccountID, in: database, db: db)
        guard !sourceOffBudget, destinationOffBudget else {
            throw LocalFirstError.unsupportedTransferWrite
        }
    }
}
