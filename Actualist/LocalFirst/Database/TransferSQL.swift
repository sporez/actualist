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
}
