import Foundation
import GRDB

extension BudgetDatabase {

    func resolveOrCreatePayeeMessages(
        selectedPayeeID: String?,
        payeeName: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (payeeID: String, messages: [ActualSyncDecodedMessage]) {
        if let selectedPayeeID, !selectedPayeeID.isEmpty {
            return (selectedPayeeID, [])
        }

        let trimmedName = payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing payee name")
        }

        if let existing = try fetchPayees().first(where: {
            $0.transferAccount == nil && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }), let id = existing.id, !id.isEmpty {
            return (id, [])
        }

        let payeeID = UUID().uuidString
        var messages: [ActualSyncDecodedMessage] = []
        try queue.read { db in
            let payeeColumns = try requiredColumns(
                table: "payees",
                required: ["name"],
                db: db
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "payees",
                    row: payeeID,
                    column: "name",
                    value: .string(trimmedName)
                )
            )
            if payeeColumns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "payees",
                        row: payeeID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }

            if try tableExists("payee_mapping", db: db) {
                _ = try requiredColumns(table: "payee_mapping", required: ["targetId"], db: db)
                messages.append(
                    try builder.makeMessage(
                        dataset: "payee_mapping",
                        row: payeeID,
                        column: "targetId",
                        value: .string(payeeID)
                    )
                )
            }
        }
        return (payeeID, messages)
    }

    func createSimpleTransactionMessages(
        _ draft: TransactionDraft,
        transactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try validateSimpleTransactionDraft(draft)
        var messages: [ActualSyncDecodedMessage] = []
        try queue.read { db in
            let columns = try requiredColumns(
                table: "transactions",
                required: ["date", "amount"],
                db: db
            )
            let accountColumn = try firstExistingColumn(["acct", "account"], in: columns, table: "transactions")
            let payeeColumn = try firstExistingColumn(["description", "payee"], in: columns, table: "transactions")
            let isParentColumn = columns.contains("is_parent") ? "is_parent" : (columns.contains("isParent") ? "isParent" : nil)
            let dateValue = try Self.actualDateValue(draft.date)

            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: accountColumn,
                    value: .string(draft.accountID)
                )
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "date",
                    value: .int(Int64(dateValue))
                )
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "amount",
                    value: .int(Int64(draft.amountMinorUnits))
                )
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: payeeColumn,
                    value: .string(payeeID)
                )
            )
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "category",
                    value: draft.categoryID.map(LocalFirstSyncValue.string) ?? .null
                )
            )
            if columns.contains("notes") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "notes",
                        value: draft.notes.map(LocalFirstSyncValue.string) ?? .null
                    )
                )
            }
            if columns.contains("cleared") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "cleared",
                        value: .bool(draft.cleared)
                    )
                )
            }
            if columns.contains("tombstone") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "tombstone",
                        value: .bool(false)
                    )
                )
            }
            if let isParentColumn {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: isParentColumn,
                        value: .bool(false)
                    )
                )
            }
            if columns.contains("parent_id") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "parent_id",
                        value: .null
                    )
                )
            }
            if let importedPayee = draft.importedPayee {
                let importedPayeeColumn = ["imported_description", "imported_payee"]
                    .first { columns.contains($0) }
                if let importedPayeeColumn {
                    messages.append(
                        try builder.makeMessage(
                            dataset: "transactions",
                            row: transactionID,
                            column: importedPayeeColumn,
                            value: .string(importedPayee)
                        )
                    )
                }
            }
            if let importedID = draft.importedID, !importedID.isEmpty {
                let importedIDColumn = try firstExistingColumn(
                    ["financial_id", "imported_id"],
                    in: columns,
                    table: "transactions"
                )
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: importedIDColumn,
                        value: .string(importedID)
                    )
                )
            }
            if let sortOrder = draft.sortOrder, columns.contains("sort_order") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "sort_order",
                        value: .double(sortOrder)
                    )
                )
            }
            if let scheduleID = draft.scheduleID, columns.contains("schedule") {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: transactionID,
                        column: "schedule",
                        value: .string(scheduleID)
                    )
                )
            }
        }
        return messages
    }

    func resolveTransactionRowColumns(db: Database) throws -> TransactionRowColumns {
        let columns = try requiredColumns(
            table: "transactions",
            required: ["date", "amount", "category"],
            db: db
        )
        return TransactionRowColumns(
            all: columns,
            account: try firstExistingColumn(["acct", "account"], in: columns, table: "transactions"),
            payee: try firstExistingColumn(["description", "payee"], in: columns, table: "transactions"),
            isParent: ["isParent", "is_parent"].first { columns.contains($0) },
            isChild: ["isChild", "is_child"].first { columns.contains($0) },
            transferID: ["transferred_id", "transfer_id"].first { columns.contains($0) },
            sortOrder: columns.contains("sort_order") ? "sort_order" : nil
        )
    }

    func transactionRowMessages(
        rowID: String,
        accountID: String,
        dateValue: Int,
        amountMinorUnits: Int,
        payeeID: String?,
        categoryID: String?,
        notes: String?,
        cleared: Bool,
        reconciled: Bool? = nil,
        isParent: Bool,
        parentID: String?,
        isChild: Bool,
        transferID: String?,
        sortOrder: Double?,
        error: SplitTransactionError? = nil,
        startingBalance: Bool? = nil,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        scheduleID: String? = nil
    ) throws -> [ActualSyncDecodedMessage] {
        var fields: [(String, LocalFirstSyncValue)] = [
            (columns.account, .string(accountID)),
            ("date", .int(Int64(dateValue))),
            ("amount", .int(Int64(amountMinorUnits))),
            (columns.payee, payeeID.map(LocalFirstSyncValue.string) ?? .null),
            ("category", categoryID.map(LocalFirstSyncValue.string) ?? .null)
        ]
        if columns.hasNotes {
            fields.append(("notes", notes.map(LocalFirstSyncValue.string) ?? .null))
        }
        if columns.hasCleared {
            fields.append(("cleared", .bool(cleared)))
        }
        if let reconciled, columns.hasReconciled {
            fields.append(("reconciled", .bool(reconciled)))
        }
        if let isParentColumn = columns.isParent {
            fields.append((isParentColumn, .bool(isParent)))
        }
        if columns.hasParentID {
            fields.append(("parent_id", parentID.map(LocalFirstSyncValue.string) ?? .null))
        }
        if let isChildColumn = columns.isChild {
            fields.append((isChildColumn, .bool(isChild)))
        }
        if let transferID, let transferColumn = columns.transferID {
            fields.append((transferColumn, .string(transferID)))
        }
        if let sortOrder, let sortOrderColumn = columns.sortOrder {
            fields.append((sortOrderColumn, .double(sortOrder)))
        }
        if columns.hasTombstone {
            fields.append(("tombstone", .bool(false)))
        }
        if let scheduleID, columns.hasSchedule {
            fields.append(("schedule", .string(scheduleID)))
        }
        if columns.hasError {
            fields.append(("error", splitErrorValue(error)))
        }
        if let startingBalance, columns.hasStartingBalance {
            fields.append(("starting_balance_flag", .bool(startingBalance)))
        }

        var messages: [ActualSyncDecodedMessage] = []
        for (column, value) in fields {
            messages.append(
                try builder.makeMessage(dataset: "transactions", row: rowID, column: column, value: value)
            )
        }
        return messages
    }

    func createTransferTransactionMessages(
        draft: TransactionDraft,
        sourceTransactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> (messages: [ActualSyncDecodedMessage], destinationAccountID: String) {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard draft.amountMinorUnits != 0 else {
            throw LocalFirstError.invalidLocalWrite("missing amount")
        }

        return try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            guard columns.transferID != nil else {
                throw LocalFirstError.invalidLocalWrite("missing column transactions.transferred_id")
            }
            if try tableExists("accounts", db: db),
               try !rowExists(table: "accounts", rowID: draft.accountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }
            let destinationAccountID = try transferDestinationAccountID(payeeID: payeeID, db: db)
            let fromPayeeID = try transferPayeeID(forAccount: draft.accountID, db: db)
            let dateValue = try Self.actualDateValue(draft.date)
            let pairedTransactionID = UUID().uuidString
            // Only the budget side of a cross-budget transfer carries a category.
            let transferCategories = try transferCategories(
                draft: draft,
                sourceAccountID: draft.accountID,
                destinationAccountID: destinationAccountID,
                db: db
            )

            let sourceMessages = try transactionRowMessages(
                rowID: sourceTransactionID,
                accountID: draft.accountID,
                dateValue: dateValue,
                amountMinorUnits: draft.amountMinorUnits,
                payeeID: payeeID,
                categoryID: transferCategories.source,
                notes: draft.notes,
                cleared: draft.cleared,
                isParent: false,
                parentID: nil,
                isChild: false,
                transferID: pairedTransactionID,
                sortOrder: nil,
                columns: columns,
                builder: &builder,
                scheduleID: draft.scheduleID
            )
            let pairedMessages = try transactionRowMessages(
                rowID: pairedTransactionID,
                accountID: destinationAccountID,
                dateValue: dateValue,
                amountMinorUnits: -draft.amountMinorUnits,
                payeeID: fromPayeeID,
                categoryID: transferCategories.destination,
                notes: draft.notes,
                cleared: false,
                isParent: false,
                parentID: nil,
                isChild: false,
                transferID: sourceTransactionID,
                sortOrder: nil,
                columns: columns,
                builder: &builder
            )
            return (sourceMessages + pairedMessages, destinationAccountID)
        }
    }

    func transferDestinationAccountID(payeeID: String, db: Database) throws -> String {
        guard try tableExists("payees", db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing payees table")
        }
        let payeeColumns = try columnSet(for: "payees", db: db)
        let transferColumn = column(
            "transfer_acct",
            fallback: column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL",
              let destination = try String.fetchOne(
                db,
                sql: "SELECT \(transferColumn) FROM payees WHERE id = ?",
                arguments: [payeeID]
              ),
              !destination.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("selected payee is not a transfer payee")
        }
        return destination
    }

    func accountOffBudget(_ accountID: String, db: Database) throws -> Bool {
        guard try tableExists("accounts", db: db) else {
            return false
        }
        let columns = try columnSet(for: "accounts", db: db)
        let offbudgetColumn = column("offbudget", fallback: "0", columns: columns)
        guard offbudgetColumn != "0" else {
            return false
        }
        let value = try Int.fetchOne(
            db,
            sql: "SELECT \(offbudgetColumn) FROM accounts WHERE id = ?",
            arguments: [accountID]
        )
        return (value ?? 0) != 0
    }

    func transferCategories(
        draft: TransactionDraft,
        sourceAccountID: String,
        destinationAccountID: String,
        db: Database
    ) throws -> (source: String?, destination: String?) {
        let sourceOffBudget = try accountOffBudget(sourceAccountID, db: db)
        let destinationOffBudget = try accountOffBudget(destinationAccountID, db: db)
        guard sourceOffBudget != destinationOffBudget else {
            return (nil, nil)
        }
        guard let categoryID = draft.categoryID else {
            return (nil, nil)
        }
        if try tableExists("categories", db: db),
           try !rowExists(table: "categories", rowID: categoryID, db: db) {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }
        return sourceOffBudget ? (nil, categoryID) : (categoryID, nil)
    }

    func transferPayeeID(forAccount account: String, db: Database) throws -> String {
        guard try tableExists("payees", db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing payees table")
        }
        let payeeColumns = try columnSet(for: "payees", db: db)
        let transferColumn = column(
            "transfer_acct",
            fallback: column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL",
              let payeeID = try String.fetchOne(
                db,
                sql: "SELECT id FROM payees WHERE \(transferColumn) = ? AND \(predicateForLiveRows(columns: payeeColumns)) LIMIT 1",
                arguments: [account]
              ),
              !payeeID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transfer payee for account")
        }
        return payeeID
    }

    func tombstoneMessage(
        rowID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> ActualSyncDecodedMessage {
        try builder.makeMessage(dataset: "transactions", row: rowID, column: "tombstone", value: .bool(true))
    }
}
