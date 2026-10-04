import Foundation
import GRDB

extension BudgetDatabase {

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
            guard try liveRowExists(table: "transactions", rowID: trimmedTransactionID, db: db) else {
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
               try !liveRowExists(table: "categories", rowID: trimmedCategoryID, db: db) {
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
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
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
            try validateReconciledMutationAuthorization(
                transactionID: trimmedTransactionID,
                authorization: reconciliationAuthorization,
                columns: columns,
                db: db
            )

            let existing = try existingTransactionState(id: trimmedTransactionID, columns: columns, db: db)
            if existing.isParent || existing.isChild {
                return try deleteSplitFamilyMessages(
                    transactionID: trimmedTransactionID,
                    columns: columns,
                    db: db,
                    builder: &builder
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
            return try plainTransactionDeleteWrite(
                transactionID: trimmedTransactionID,
                accountID: existing.account,
                pair: pair,
                columns: columns,
                builder: &builder
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
}
