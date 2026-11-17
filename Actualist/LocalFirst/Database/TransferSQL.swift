import Foundation
import GRDB

enum TransferSQL {
    static func transferDestinationAccountID(payeeID: String, in database: isolated BudgetDatabase, db: Database) throws -> String {
        guard try database.tableExists("payees", db: db) else {
            throw LocalFirstError.schemaUnavailable("missing payees table")
        }
        let payeeColumns = try database.columnSet(for: "payees", db: db)
        let transferColumn = database.column(
            "transfer_acct",
            fallback: database.column("transferAccount", fallback: "NULL", columns: payeeColumns),
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

    static func transferAccountID(ifPayee payeeID: String?, in database: isolated BudgetDatabase) throws -> String? {
        try database.queue.read { db in
            try transferAccountID(ifPayee: payeeID, in: database, db: db)
        }
    }

    static func transferCategories(
        draft: TransactionDraft,
        sourceAccountID: String,
        destinationAccountID: String,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (source: String?, destination: String?) {
        let sourceOffBudget = try AccountSQL.accountOffBudget(sourceAccountID, in: database, db: db)
        let destinationOffBudget = try AccountSQL.accountOffBudget(destinationAccountID, in: database, db: db)
        guard sourceOffBudget != destinationOffBudget else {
            return (nil, nil)
        }
        guard let categoryID = draft.categoryID else {
            return (nil, nil)
        }
        if try database.tableExists("categories", db: db),
           try !database.liveRowExists(table: "categories", rowID: categoryID, db: db) {
            throw LocalFirstError.referencedRowUnavailable("missing category")
        }
        return sourceOffBudget ? (nil, categoryID) : (categoryID, nil)
    }

    static func transferPayeeID(forAccount account: String, in database: isolated BudgetDatabase, db: Database) throws -> String {
        guard try database.tableExists("payees", db: db) else {
            throw LocalFirstError.schemaUnavailable("missing payees table")
        }
        let payeeColumns = try database.columnSet(for: "payees", db: db)
        let transferColumn = database.column(
            "transfer_acct",
            fallback: database.column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL",
              let payeeID = try String.fetchOne(
                db,
                sql: "SELECT id FROM payees WHERE \(transferColumn) = ? AND \(database.predicateForLiveRows(columns: payeeColumns)) LIMIT 1",
                arguments: [account]
              ),
              !payeeID.isEmpty else {
            throw LocalFirstError.referencedRowUnavailable("missing transfer payee for account")
        }
        return payeeID
    }

    static func transferAccountID(ifPayee payeeID: String?, in database: isolated BudgetDatabase, db: Database) throws -> String? {
        guard let payeeID, !payeeID.isEmpty, try database.tableExists("payees", db: db) else {
            return nil
        }
        let payeeColumns = try database.columnSet(for: "payees", db: db)
        let transferColumn = database.column(
            "transfer_acct",
            fallback: database.column("transferAccount", fallback: "NULL", columns: payeeColumns),
            columns: payeeColumns
        )
        guard transferColumn != "NULL" else { return nil }
        return try String.fetchOne(
            db,
            sql: "SELECT \(transferColumn) FROM payees WHERE id = ?",
            arguments: [payeeID]
        ).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Transfer legs

    static func prepareTransferOnInsert(
        _ row: SplitTransactionRecord,
        columns: TransactionRowColumns,
        affectedAccounts: inout Set<String>,
        affectedTransactions: inout Set<String>,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (row: SplitTransactionRecord, messages: [ActualSyncDecodedMessage]) {
        guard !row.isParent,
              let destination = try TransferSQL.transferAccountID(ifPayee: row.payee, in: database, db: db),
              columns.transferID != nil,
              let account = row.account else {
            return (row, [])
        }
        let pairedID = UUID().uuidString
        let fromPayeeID = try TransferSQL.transferPayeeID(forAccount: account, in: database, db: db)
        let clearCategory = try AccountSQL.accountOffBudget(account, in: database, db: db) == AccountSQL.accountOffBudget(destination, in: database, db: db)
        var next = row
        next.transferID = pairedID
        if clearCategory {
            next.category = nil
        }
        affectedAccounts.insert(destination)
        affectedTransactions.insert(pairedID)
        let paired = try columns.rowMessages(
            rowID: pairedID,
            accountID: destination,
            dateValue: PackedDate.packed(fromISO: row.date),
            amountMinorUnits: -row.amount,
            payeeID: fromPayeeID,
            categoryID: nil,
            notes: row.notes,
            cleared: false,
            isParent: false,
            parentID: nil,
            isChild: false,
            transferID: row.id,
            sortOrder: nil,
            builder: &builder,
            cells: .snapshot
        )
        return (next, paired)
    }

    static func transferMessagesOnUpdate(
        old: SplitTransactionRecord,
        new: SplitTransactionRecord,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> (messages: [ActualSyncDecodedMessage], accounts: Set<String>, transactions: Set<String>) {
        // An untouched row must not create or unlink a transfer. Amount and notes
        // matter only when they have to reach an existing pair.
        let linkInputsUnchanged = old.account == new.account && old.payee == new.payee
            && old.transferID == new.transferID && old.isParent == new.isParent
        if linkInputsUnchanged, old.transferID == nil || (old.amount == new.amount && old.notes == new.notes) {
            return ([], [], [])
        }
        if new.isParent {
            return try transferMessagesOnDelete(old, columns: columns, builder: &builder, db: db)
        }
        let destination = try TransferSQL.transferAccountID(ifPayee: new.payee, in: database, db: db)
        if destination != nil, new.transferID == nil, old.transferID == nil {
            var accounts: Set<String> = []
            var transactions: Set<String> = []
            let prepared = try prepareTransferOnInsert(
                new,
                columns: columns,
                affectedAccounts: &accounts,
                affectedTransactions: &transactions,
                builder: &builder,
                in: database,
                db: db
            )
            var messages = prepared.messages
            if let transferColumn = columns.transferID, let transferID = prepared.row.transferID {
                messages.append(
                    try builder.makeMessage(
                        dataset: "transactions",
                        row: new.id,
                        column: transferColumn,
                        value: .string(transferID)
                    )
                )
            }
            if prepared.row.category == nil, old.category != nil {
                messages.append(
                    try builder.makeMessage(dataset: "transactions", row: new.id, column: "category", value: .null)
                )
            }
            return (messages, accounts, transactions)
        }
        if destination == nil, old.transferID != nil {
            return try transferMessagesOnDelete(old, columns: columns, builder: &builder, db: db)
        }
        if old.account == new.account,
           old.payee == new.payee,
           old.amount == new.amount,
           old.notes == new.notes {
            return ([], [], [])
        }
        guard let destination, let pairedID = new.transferID ?? old.transferID, let account = new.account else {
            return ([], [], [])
        }
        let fromPayeeID = try TransferSQL.transferPayeeID(forAccount: account, in: database, db: db)
        var messages: [ActualSyncDecodedMessage] = []
        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.account, value: .string(destination)))
        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .string(fromPayeeID)))
        if columns.hasNotes {
            messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "notes", value: new.notes.map(LocalFirstSyncValue.string) ?? .null))
        }
        messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "amount", value: .int(Int64(-new.amount))))
        if try AccountSQL.accountOffBudget(account, in: database, db: db) == AccountSQL.accountOffBudget(destination, in: database, db: db) {
            messages.append(try builder.makeMessage(dataset: "transactions", row: new.id, column: "category", value: .null))
            messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: "category", value: .null))
        }
        return (messages, [destination], [pairedID])
    }

    static func transferMessagesOnDelete(
        _ old: SplitTransactionRecord,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder,
        db: Database
    ) throws -> (messages: [ActualSyncDecodedMessage], accounts: Set<String>, transactions: Set<String>) {
        guard let pairedID = old.transferID, let transferColumn = columns.transferID else {
            return ([], [], [])
        }
        var messages: [ActualSyncDecodedMessage] = []
        var accounts: Set<String> = []
        if let paired = try SplitFamilySQL.loadTransactionRecord(id: pairedID, columns: columns, db: db) {
            if let account = paired.account {
                accounts.insert(account)
            }
            if paired.isChild {
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: transferColumn, value: .null))
                messages.append(try builder.makeMessage(dataset: "transactions", row: pairedID, column: columns.payee, value: .null))
            } else if columns.hasTombstone {
                messages.append(try builder.tombstone(dataset: "transactions", row: pairedID))
            }
        }
        if !old.deleted {
            messages.append(try builder.makeMessage(dataset: "transactions", row: old.id, column: transferColumn, value: .null))
        }
        return (messages, accounts, [pairedID])
    }
}
