import Foundation
import GRDB

extension BudgetDatabase {
    func fetchTransactionCSVExportRows(
        accountID: String,
        query: TransactionFeedQuery
    ) throws -> [TransactionCSVExportRow] {
        try withTransactionQuerySnapshot(scope: .account(accountID), query: query) { db, transactions in
            let accountNames = try Self.transactionCSVNameMap(table: "accounts", db: db)
            let categoryNames = try Self.transactionCSVCategoryNames(db: db)
            let physical = transactions.flatMap { [$0] + $0.subtransactions }
            var seenIDs = Set<String>()
            return physical.compactMap { transaction in
                guard let id = transaction.id, seenIDs.insert(id).inserted else { return nil }
                let familyID = transaction.isChild ? transaction.parentID ?? id : id
                let category = categoryNames[transaction.category ?? ""]
                return TransactionCSVExportRow(
                    id: id,
                    familyID: familyID,
                    accountName: accountNames[transaction.account] ?? "",
                    date: transaction.date,
                    payeeName: transaction.payeeName ?? "",
                    notes: transaction.notes,
                    categoryGroupName: category?.group ?? "",
                    categoryName: category?.name ?? "",
                    amountMinorUnits: transaction.amount ?? 0,
                    isCleared: transaction.cleared?.boolValue ?? false,
                    isReconciled: transaction.reconciled,
                    isParent: transaction.isParent,
                    isChild: transaction.isChild
                )
            }
        }
    }

    private static func transactionCSVNameMap(table: String, db: Database) throws -> [String: String] {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [table]
        ) ?? false else { return [:] }
        return Dictionary(
            try Row.fetchAll(db, sql: "SELECT id, name FROM \(table)")
                .compactMap { row -> (String, String)? in
                    guard let id = row["id"] as String? else { return nil }
                    return (id, row["name"] as String? ?? "")
                },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private static func transactionCSVCategoryNames(db: Database) throws -> [String: (group: String, name: String)] {
        let hasCategories = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'categories')"
        ) ?? false
        guard hasCategories else { return [:] }
        let categoryColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(categories)").compactMap { $0["name"] as String? })
        let groupColumn = ["cat_group", "group_id"].first(where: categoryColumns.contains)
        let groups = try transactionCSVNameMap(table: "category_groups", db: db)
        let groupExpression = groupColumn.map { "c.\($0)" } ?? "NULL"
        let rows = try Row.fetchAll(db, sql: "SELECT c.id, c.name, \(groupExpression) AS group_id FROM categories c")
        return Dictionary(
            rows.compactMap { row -> (String, (group: String, name: String))? in
                guard let id = row["id"] as String? else { return nil }
                let groupID = row["group_id"] as String?
                return (id, (groupID.flatMap { groups[$0] } ?? "", row["name"] as String? ?? ""))
            },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}
