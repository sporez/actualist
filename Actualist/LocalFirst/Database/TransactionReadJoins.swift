import Foundation
import GRDB

struct TransactionReadJoins {
    let sql: String
    /// Actual's public `payee`: the mapped payee id, NULL when that payee is deleted.
    let livePayee: String
    /// Actual's public `category`: the mapped category id, NULL when that category is deleted.
    let liveCategory: String
    let transferIDExpression: String
    let isTransferExpression: String
    /// True when the live payee is a transfer payee (`payee.transfer_acct` non-empty), whether or not
    /// the row is linked. "0" when the payee table or column is unavailable.
    let isTransferPayeeExpression: String
    let payeeNameSelect: String
    let categoryNameSelect: String
}

extension TransactionReadJoins {
    /// The joins and expressions that read Actual's public transaction fields
    /// over `split`'s table. `includeNames` also joins the payee and category
    /// names.
    static func resolve(
        split: TransactionSplitQueryExpressions,
        transactionColumns: Set<String>,
        includeNames: Bool,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> TransactionReadJoins {
        let transferColumn = try database.categoryMappingTransferColumn(db: db)
        let mappedCategory = transferColumn.map {
            "COALESCE(cm.\(database.quotedIdentifier($0)), \(split.qualifiedCategory))"
        } ?? split.qualifiedCategory
        let categoryMappingJoin = transferColumn == nil
            ? ""
            : "LEFT JOIN category_mapping cm ON cm.id = \(split.qualifiedCategory)"

        let hasTransactionPayee = TransactionRowColumns.payee(in: transactionColumns) != nil
        let payeeMappingTarget: String?
        if hasTransactionPayee, try database.tableExists("payee_mapping", db: db) {
            let mappingColumns = try database.columnSet(for: "payee_mapping", db: db)
            payeeMappingTarget = ["targetId", "target_id"].first(where: mappingColumns.contains)
        } else {
            payeeMappingTarget = nil
        }
        let mappedPayee = payeeMappingTarget.map {
            "COALESCE(pm.\($0), \(split.qualifiedPayee))"
        } ?? split.qualifiedPayee
        let payeeMappingJoin = payeeMappingTarget == nil
            ? ""
            : "LEFT JOIN payee_mapping pm ON pm.id = \(split.qualifiedPayee)"

        // Actual's logical transfer_id maps to transferred_id in persisted budgets.
        let transferIDColumn = TransactionRowColumns.transferID(in: transactionColumns)
        let transferIDExpression = transferIDColumn.map { "\(split.tableAlias).\($0)" } ?? "NULL"
        var transferPredicates: [String] = []
        var transferPayeePredicate: String?
        if transferIDColumn != nil {
            transferPredicates.append(
                "(\(transferIDExpression) IS NOT NULL AND \(transferIDExpression) != '')"
            )
        }

        var payeeJoin = ""
        var payeeAccountJoin = ""
        var payeeNameSelect = "NULL"
        var livePayee = mappedPayee
        if try database.tableExists("payees", db: db) {
            let payeeColumns = try database.columnSet(for: "payees", db: db)
            let transferAccount = ["transfer_acct", "transfer_account"]
                .first(where: payeeColumns.contains)
            if hasTransactionPayee || includeNames {
                let livePredicate = database.predicateForLiveRows(columns: payeeColumns, tableAlias: "py")
                payeeJoin = "LEFT JOIN payees py ON py.id = \(mappedPayee) AND \(livePredicate)"
                livePayee = "py.id"
            }
            if hasTransactionPayee, let transferAccount {
                let payeePredicate = "(py.\(transferAccount) IS NOT NULL AND py.\(transferAccount) != '')"
                transferPredicates.append(payeePredicate)
                transferPayeePredicate = payeePredicate
            }
            if includeNames {
                if let transferAccount, try database.tableExists("accounts", db: db) {
                    payeeAccountJoin = "LEFT JOIN accounts pax ON pax.id = py.\(transferAccount)"
                    payeeNameSelect = "COALESCE(NULLIF(py.name, ''), pax.name)"
                } else {
                    payeeNameSelect = "py.name"
                }
            }
        }
        // Reports and backend transaction queries must classify both graph and payee transfers.
        let isTransferExpression = transferPredicates.isEmpty
            ? "0"
            : "CASE WHEN \(transferPredicates.joined(separator: " OR ")) THEN 1 ELSE 0 END"

        var categoryJoin = ""
        var categoryNameSelect = "NULL"
        var liveCategory = mappedCategory
        if try database.tableExists("categories", db: db) {
            let categoryColumns = try database.columnSet(for: "categories", db: db)
            let livePredicate = database.predicateForLiveRows(columns: categoryColumns, tableAlias: "cat")
            categoryJoin = "LEFT JOIN categories cat ON cat.id = \(mappedCategory) AND \(livePredicate)"
            liveCategory = "cat.id"
            if includeNames { categoryNameSelect = "cat.name" }
        }

        return TransactionReadJoins(
            sql: [categoryMappingJoin, payeeMappingJoin, payeeJoin, payeeAccountJoin, categoryJoin]
                .filter { !$0.isEmpty }
                .joined(separator: "\n"),
            livePayee: livePayee,
            liveCategory: liveCategory,
            transferIDExpression: transferIDExpression,
            isTransferExpression: isTransferExpression,
            isTransferPayeeExpression: transferPayeePredicate.map { "CASE WHEN \($0) THEN 1 ELSE 0 END" } ?? "0",
            payeeNameSelect: payeeNameSelect,
            categoryNameSelect: categoryNameSelect
        )
    }
}
