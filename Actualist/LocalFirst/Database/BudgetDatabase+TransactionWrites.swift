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
        isParent: Bool,
        parentID: String?,
        isChild: Bool,
        transferID: String?,
        sortOrder: Double?,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
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
                builder: &builder
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

    func createSplitTransactionMessages(
        draft: TransactionDraft,
        parentTransactionID: String,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard draft.splits.count >= 2 else {
            throw LocalFirstError.invalidLocalWrite("split requires at least two categories")
        }
        let splitTotal = draft.splits.reduce(0) { $0 + $1.amountMinorUnits }
        guard splitTotal == draft.amountMinorUnits else {
            throw LocalFirstError.invalidLocalWrite("split amounts do not sum to the transaction total")
        }

        return try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            if try tableExists("accounts", db: db),
               try !rowExists(table: "accounts", rowID: draft.accountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }
            let dateValue = try Self.actualDateValue(draft.date)

            var messages = try transactionRowMessages(
                rowID: parentTransactionID,
                accountID: draft.accountID,
                dateValue: dateValue,
                amountMinorUnits: draft.amountMinorUnits,
                payeeID: payeeID,
                categoryID: nil,
                notes: draft.notes,
                cleared: draft.cleared,
                isParent: true,
                parentID: nil,
                isChild: false,
                transferID: nil,
                sortOrder: nil,
                columns: columns,
                builder: &builder
            )
            for (index, split) in draft.splits.enumerated() {
                if let categoryID = split.categoryID,
                   try tableExists("categories", db: db),
                   try !rowExists(table: "categories", rowID: categoryID, db: db) {
                    throw LocalFirstError.invalidLocalWrite("missing category")
                }
                messages.append(contentsOf: try transactionRowMessages(
                    rowID: UUID().uuidString,
                    accountID: draft.accountID,
                    dateValue: dateValue,
                    amountMinorUnits: split.amountMinorUnits,
                    payeeID: payeeID,
                    categoryID: split.categoryID,
                    notes: nil,
                    cleared: draft.cleared,
                    isParent: false,
                    parentID: parentTransactionID,
                    isChild: true,
                    transferID: nil,
                    sortOrder: Double(-(index + 1)),
                    columns: columns,
                    builder: &builder
                ))
            }
            return messages
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

    func updateTransactionMessages(
        transactionID: String,
        draft: TransactionDraft,
        payeeID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard draft.amountMinorUnits != 0 else {
            throw LocalFirstError.invalidLocalWrite("missing amount")
        }
        if draft.isSplit {
            let splitTotal = draft.splits.reduce(0) { $0 + $1.amountMinorUnits }
            guard splitTotal == draft.amountMinorUnits else {
                throw LocalFirstError.invalidLocalWrite("split amounts do not sum to the transaction total")
            }
        }

        return try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            guard try rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }
            if try tableExists("accounts", db: db),
               try !rowExists(table: "accounts", rowID: draft.accountID, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing account")
            }

            let existing = try existingTransactionState(id: trimmedTransactionID, columns: columns, db: db)
            let dateValue = try Self.actualDateValue(draft.date)
            let isTransferDraft = draft.isTransfer && !draft.isSplit
            let mainCategory: String?
            let pairedCategory: String?
            if draft.isSplit {
                mainCategory = nil
                pairedCategory = nil
            } else if isTransferDraft {
                // Put the category on the budget side of a cross-budget transfer.
                let destination = try transferDestinationAccountID(payeeID: payeeID, db: db)
                let categories = try transferCategories(
                    draft: draft,
                    sourceAccountID: draft.accountID,
                    destinationAccountID: destination,
                    db: db
                )
                mainCategory = categories.source
                pairedCategory = categories.destination
            } else {
                mainCategory = draft.categoryID
                pairedCategory = nil
            }
            if let mainCategory,
               try tableExists("categories", db: db),
               try !rowExists(table: "categories", rowID: mainCategory, db: db) {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            var messages: [ActualSyncDecodedMessage] = []
            var affectedAccounts: Set<String> = [existing.account, draft.accountID]
            var affectedTransactions: Set<String> = [trimmedTransactionID]

            messages += try transactionRowMessages(
                rowID: trimmedTransactionID,
                accountID: draft.accountID,
                dateValue: dateValue,
                amountMinorUnits: draft.amountMinorUnits,
                payeeID: payeeID,
                categoryID: mainCategory,
                notes: draft.notes,
                cleared: draft.cleared,
                isParent: draft.isSplit,
                parentID: nil,
                isChild: false,
                transferID: nil,
                sortOrder: nil,
                columns: columns,
                builder: &builder
            )

            if draft.isSplit {
                var keptChildIDs = Set<String>()
                for (index, split) in draft.splits.enumerated() {
                    if let categoryID = split.categoryID,
                       try tableExists("categories", db: db),
                       try !rowExists(table: "categories", rowID: categoryID, db: db) {
                        throw LocalFirstError.invalidLocalWrite("missing category")
                    }
                    let childID: String
                    let sortOrder: Double?
                    if let existingID = split.id, existing.childIDs.contains(existingID) {
                        childID = existingID
                        sortOrder = nil
                        keptChildIDs.insert(existingID)
                    } else {
                        childID = UUID().uuidString
                        sortOrder = Double(-(index + 1))
                    }
                    affectedTransactions.insert(childID)
                    messages += try transactionRowMessages(
                        rowID: childID,
                        accountID: draft.accountID,
                        dateValue: dateValue,
                        amountMinorUnits: split.amountMinorUnits,
                        payeeID: payeeID,
                        categoryID: split.categoryID,
                        notes: nil,
                        cleared: draft.cleared,
                        isParent: false,
                        parentID: trimmedTransactionID,
                        isChild: true,
                        transferID: nil,
                        sortOrder: sortOrder,
                        columns: columns,
                        builder: &builder
                    )
                }
                for childID in existing.childIDs where !keptChildIDs.contains(childID) {
                    affectedTransactions.insert(childID)
                    messages.append(try tombstoneMessage(rowID: childID, builder: &builder))
                }
            } else {
                for childID in existing.childIDs {
                    affectedTransactions.insert(childID)
                    messages.append(try tombstoneMessage(rowID: childID, builder: &builder))
                }
            }

            // Keep transfer transitions aligned with loot-core's onUpdate.
            messages += try transferTransitionMessages(
                mainID: trimmedTransactionID,
                draft: draft,
                payeeID: payeeID,
                dateValue: dateValue,
                pairedCategory: pairedCategory,
                existing: existing,
                columns: columns,
                affectedAccounts: &affectedAccounts,
                affectedTransactions: &affectedTransactions,
                db: db,
                builder: &builder
            )

            return TransactionWriteResult(
                messages: messages,
                affectedAccountIDs: Array(affectedAccounts),
                affectedTransactionIDs: Array(affectedTransactions)
            )
        }
    }

    func existingTransactionState(
        id: String,
        columns: TransactionRowColumns,
        db: Database
    ) throws -> ExistingTransactionState {
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
                sql: "SELECT id FROM transactions WHERE parent_id = ? AND \(predicateForLiveRows(columns: columns.all))",
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

        return ExistingTransactionState(
            account: account,
            isParent: isParent,
            transferID: transferID,
            childIDs: childIDs,
            pairedAccount: pairedAccount,
            pairedIsChild: pairedIsChild
        )
    }

    func transferTransitionMessages(
        mainID: String,
        draft: TransactionDraft,
        payeeID: String,
        dateValue: Int,
        pairedCategory: String?,
        existing: ExistingTransactionState,
        columns: TransactionRowColumns,
        affectedAccounts: inout Set<String>,
        affectedTransactions: inout Set<String>,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        // Split parents cannot be transfers.
        let nowTransfer = draft.isTransfer && !draft.isSplit
        var messages: [ActualSyncDecodedMessage] = []

        if nowTransfer {
            guard let transferColumn = columns.transferID else {
                throw LocalFirstError.invalidLocalWrite("missing column transactions.transferred_id")
            }
            let destination = try transferDestinationAccountID(payeeID: payeeID, db: db)
            let fromPayeeID = try transferPayeeID(forAccount: draft.accountID, db: db)
            affectedAccounts.insert(destination)
            if let oldPaired = existing.pairedAccount {
                affectedAccounts.insert(oldPaired)
            }

            if let pairedID = existing.transferID {
                // loot-core leaves the paired row's date and cleared state unchanged.
                affectedTransactions.insert(pairedID)
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.account, value: .string(destination)))
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .string(fromPayeeID)))
                if columns.hasNotes {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "notes", value: draft.notes.map(LocalFirstSyncValue.string) ?? .null))
                }
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "amount", value: .int(Int64(-draft.amountMinorUnits))))
                let sourceOffBudget = try accountOffBudget(draft.accountID, db: db)
                let destinationOffBudget = try accountOffBudget(destination, db: db)
                if sourceOffBudget == destinationOffBudget || destinationOffBudget {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "category", value: .null))
                } else if let pairedCategory {
                    // The off-budget editor may not have loaded the paired row's category.
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "category", value: .string(pairedCategory)))
                }
            } else {
                let pairedID = UUID().uuidString
                affectedTransactions.insert(pairedID)
                messages += try transactionRowMessages(
                    rowID: pairedID,
                    accountID: destination,
                    dateValue: dateValue,
                    amountMinorUnits: -draft.amountMinorUnits,
                    payeeID: fromPayeeID,
                    categoryID: pairedCategory,
                    notes: draft.notes,
                    cleared: false,
                    isParent: false,
                    parentID: nil,
                    isChild: false,
                    transferID: mainID,
                    sortOrder: nil,
                    columns: columns,
                    builder: &builder
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
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "tombstone", value: .bool(true)))
            }
            messages.append(try builder.makeMessage(dataset: "transactions", row: mainID, column: transferColumn, value: .null))
        }

        return messages
    }

    func tombstoneMessage(
        rowID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> ActualSyncDecodedMessage {
        try builder.makeMessage(dataset: "transactions", row: rowID, column: "tombstone", value: .bool(true))
    }

    func categorizeTransactionMessages(
        transactionID: String,
        categoryID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategoryID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard !trimmedCategoryID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try queue.read { db in
            let transactionColumns = try requiredColumns(
                table: "transactions",
                required: ["category"],
                db: db
            )
            guard try rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }

            let payeeColumn = try firstExistingColumn(["description", "payee"], in: transactionColumns, table: "transactions")
            try validateCategorizationTarget(
                transactionID: trimmedTransactionID,
                columns: transactionColumns,
                payeeColumn: payeeColumn,
                db: db
            )
            if try tableExists("categories", db: db),
               try !rowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
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
    }

    func deleteTransactionMessages(
        transactionID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> TransactionWriteResult {
        let trimmedTransactionID = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTransactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }

        return try queue.read { db in
            let columns = try resolveTransactionRowColumns(db: db)
            guard columns.hasTombstone else {
                throw LocalFirstError.invalidLocalWrite("missing column transactions.tombstone")
            }
            guard try rowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing transaction")
            }

            let existing = try existingTransactionState(id: trimmedTransactionID, columns: columns, db: db)
            var affectedAccounts: Set<String> = [existing.account]
            var affectedTransactions: Set<String> = [trimmedTransactionID]
            var messages = [try tombstoneMessage(rowID: trimmedTransactionID, builder: &builder)]

            for childID in existing.childIDs {
                affectedTransactions.insert(childID)
                messages.append(try tombstoneMessage(rowID: childID, builder: &builder))
            }

            if let pairedID = existing.transferID, let transferColumn = columns.transferID {
                affectedTransactions.insert(pairedID)
                if let oldPaired = existing.pairedAccount {
                    affectedAccounts.insert(oldPaired)
                }
                if existing.pairedIsChild {
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: transferColumn, value: .null))
                    messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .null))
                } else {
                    messages.append(try tombstoneMessage(rowID: pairedID, builder: &builder))
                }
            }

            return TransactionWriteResult(
                messages: messages,
                affectedAccountIDs: Array(affectedAccounts),
                affectedTransactionIDs: Array(affectedTransactions)
            )
        }
    }

    func validateCategorizationTarget(
        transactionID: String,
        columns: Set<String>,
        payeeColumn: String,
        db: Database
    ) throws {
        let isParentColumn = column(
            "is_parent",
            fallback: column("isParent", fallback: "0", columns: columns),
            columns: columns
        )
        if let isParent = try Int.fetchOne(
            db,
            sql: "SELECT \(isParentColumn) FROM transactions WHERE id = ?",
            arguments: [transactionID]
        ), isParent != 0 {
            throw LocalFirstError.unsupportedSplitWrite
        }
        if columns.contains("parent_id"),
           let parentID = try String.fetchOne(
            db,
            sql: "SELECT parent_id FROM transactions WHERE id = ?",
            arguments: [transactionID]
           ),
           !parentID.isEmpty {
            throw LocalFirstError.unsupportedSplitWrite
        }
        guard try tableExists("payees", db: db),
              let payeeID = try String.fetchOne(
            db,
            sql: "SELECT \(payeeColumn) FROM transactions WHERE id = ?",
            arguments: [transactionID]
              ) else {
            return
        }

        let payeeColumns = try columnSet(for: "payees", db: db)
        let transferColumn = column(
            "transfer_acct",
            fallback: column("transferAccount", fallback: "NULL", columns: payeeColumns),
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
            sql: "SELECT \(column("acct", fallback: "account", columns: columns)) FROM transactions WHERE id = ?",
            arguments: [transactionID]
        ) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction account")
        }
        let sourceOffBudget = try accountOffBudget(sourceAccountID, db: db)
        let destinationOffBudget = try accountOffBudget(destinationAccountID, db: db)
        guard !sourceOffBudget, destinationOffBudget else {
            throw LocalFirstError.unsupportedTransferWrite
        }
    }

    func validateSimpleTransactionDraft(_ draft: TransactionDraft) throws {
        guard !draft.isSplit else {
            throw LocalFirstError.unsupportedSplitWrite
        }
        guard !draft.isTransfer else {
            throw LocalFirstError.unsupportedTransferWrite
        }
        guard !draft.accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        guard draft.amountMinorUnits != 0 else {
            throw LocalFirstError.invalidLocalWrite("missing amount")
        }
    }
}
