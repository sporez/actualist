import Foundation
import GRDB

extension BudgetDatabase {

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
            let isFamilyWrite = existing.isParent || existing.isChild || draft.isSplit
            if !isFamilyWrite {
                guard draft.amountMinorUnits != 0 else {
                    throw LocalFirstError.invalidLocalWrite("missing amount")
                }
            } else {
                return try splitFamilyUpdateMessages(
                    transactionID: trimmedTransactionID,
                    draft: draft,
                    payeeID: payeeID,
                    columns: columns,
                    db: db,
                    builder: &builder
                )
            }
            let dateValue = try Self.actualDateValue(draft.date)
            let isTransferDraft = draft.isTransfer
            let mainCategory: String?
            let pairedCategory: String?
            if isTransferDraft {
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
                reconciled: draft.reconciled,
                isParent: false,
                parentID: nil,
                isChild: false,
                transferID: nil,
                sortOrder: nil,
                columns: columns,
                builder: &builder,
                scheduleID: draft.scheduleID
            )

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
            isChild: isChild,
            parentID: parentID,
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
