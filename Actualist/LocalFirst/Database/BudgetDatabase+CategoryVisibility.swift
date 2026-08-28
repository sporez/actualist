import Foundation
import GRDB

extension BudgetDatabase {
    func setCategoryHiddenMessages(
        categoryID: String,
        hidden: Bool,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try queue.read { db in
            let categoryColumns = try requiredColumns(
                table: "categories",
                required: ["hidden"],
                db: db
            )
            let groupColumn = try firstExistingColumn(
                ["cat_group", "group_id"],
                in: categoryColumns,
                table: "categories"
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, hidden, \(groupColumn) AS group_id
                    FROM categories
                    WHERE id = ? AND \(predicateForLiveRows(columns: categoryColumns))
                    LIMIT 1
                    """,
                arguments: [trimmedID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            let groupID = row["group_id"] as String?
            if let groupID, try tableExists("category_groups", db: db) {
                let groupColumns = try columnSet(for: "category_groups", db: db)
                if groupColumns.contains("hidden"),
                   let groupRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT hidden
                        FROM category_groups
                        WHERE id = ? AND \(predicateForLiveRows(columns: groupColumns))
                        LIMIT 1
                        """,
                    arguments: [groupID]
                   ),
                   flexibleBool(groupRow["hidden"]) {
                    throw LocalFirstError.invalidLocalWrite("cannot change a category in a hidden group")
                }
            }

            if flexibleBool(row["hidden"]) == hidden {
                return []
            }
            return [
                try builder.makeMessage(
                    dataset: "categories",
                    row: trimmedID,
                    column: "hidden",
                    value: .bool(hidden)
                )
            ]
        }
    }

    func setCategoryGroupHiddenMessages(
        groupID: String,
        hidden: Bool,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category group")
        }

        return try queue.read { db in
            let groupColumns = try requiredColumns(
                table: "category_groups",
                required: ["hidden"],
                db: db
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, hidden, \(column("is_income", fallback: "0", columns: groupColumns)) AS is_income
                    FROM category_groups
                    WHERE id = ? AND \(predicateForLiveRows(columns: groupColumns))
                    LIMIT 1
                    """,
                arguments: [trimmedID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category group")
            }

            if flexibleBool(row["is_income"]) {
                throw LocalFirstError.invalidLocalWrite("income groups cannot be hidden")
            }
            if flexibleBool(row["hidden"]) == hidden {
                return []
            }
            return [
                try builder.makeMessage(
                    dataset: "category_groups",
                    row: trimmedID,
                    column: "hidden",
                    value: .bool(hidden)
                )
            ]
        }
    }
}
