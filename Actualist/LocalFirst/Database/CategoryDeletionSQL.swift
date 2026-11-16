import Foundation
import GRDB

enum CategoryDeletionSQL {
    static func categoryNeedsTransfer(categoryID: String, in database: isolated BudgetDatabase) throws -> Bool {
        let id = try CategorySQL.validatedCategoryLifecycleID(categoryID, kind: "category")
        return try database.queue.read { db in
            _ = try CategorySQL.requiredCategory(id, in: database, db: db)
            return try categoryNeedsTransfer(categoryID: id, in: database, db: db)
        }
    }

    static func deleteCategoryMessages(
        categoryID: String,
        transferCategoryID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try CategorySQL.validatedCategoryLifecycleID(categoryID, kind: "category")
        let transferID = try transferCategoryID.map {
            try CategorySQL.validatedCategoryLifecycleID($0, kind: "transfer category")
        }
        return try database.queue.read { db in
            let category = try CategorySQL.requiredCategory(id, in: database, db: db)
            try CategorySQL.requireCategoryManagementAllowed(isIncome: category.isIncome, kind: "categories", in: database, db: db)
            _ = try database.requiredColumns(table: "categories", required: ["tombstone"], db: db)
            if transferID == nil, try categoryNeedsTransfer(categoryID: id, in: database, db: db) {
                throw LocalFirstError.refusedChange("Choose a category to move this category's transactions to before deleting it.")
            }

            var messages: [ActualSyncDecodedMessage] = []
            if let transferID {
                let destination = try CategorySQL.requiredCategory(transferID, in: database, db: db)
                guard destination.id != category.id else {
                    throw LocalFirstError.refusedChange("Choose a different category to move the transactions to.")
                }
                guard destination.isIncome == category.isIncome else {
                    throw LocalFirstError.refusedChange("Income and expense categories cannot be mixed.")
                }
                if !category.isIncome {
                    messages += try categoryBudgetTransferMessages(
                        sourceCategoryIDs: [category.id], destinationCategoryID: destination.id,
                        builder: &builder, in: database, db: db
                    )
                }
                messages += try categoryMappingTransferMessages(
                    sourceCategoryIDs: [category.id], destinationCategoryID: destination.id,
                    builder: &builder, in: database, db: db
                )
            }
            messages.append(try builder.tombstone(dataset: "categories", row: category.id))
            return messages
        }
    }

    static func deleteCategoryGroupMessages(
        groupID: String,
        transferCategoryID: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try CategorySQL.validatedCategoryLifecycleID(groupID, kind: "category group")
        let transferID = try transferCategoryID.map {
            try CategorySQL.validatedCategoryLifecycleID($0, kind: "transfer category")
        }
        return try database.queue.read { db in
            let group = try CategorySQL.requiredCategoryGroup(id, in: database, db: db)
            try CategorySQL.requireCategoryManagementAllowed(isIncome: group.isIncome, kind: "groups", in: database, db: db)
            _ = try database.requiredColumns(table: "category_groups", required: ["tombstone"], db: db)
            let allChildren = try categoryLifecycleRows(groupID: group.id, includeTombstones: true, in: database, db: db)
            let liveChildren = try CategorySQL.liveCategoryRows(groupID: group.id, in: database, db: db)
            if transferID == nil,
               try liveChildren.contains(where: { try categoryNeedsTransfer(categoryID: $0.id, in: database, db: db) }) {
                throw LocalFirstError.refusedChange("Choose a category to move this group's transactions to before deleting it.")
            }

            var messages: [ActualSyncDecodedMessage] = []
            if let transferID {
                let destination = try CategorySQL.requiredCategory(transferID, in: database, db: db)
                guard destination.groupID != group.id else {
                    throw LocalFirstError.refusedChange("Choose a category outside this group to move the transactions to.")
                }
                guard destination.isIncome == group.isIncome else {
                    throw LocalFirstError.refusedChange("Income and expense categories cannot be mixed.")
                }
                guard allChildren.allSatisfy({ $0.isIncome == destination.isIncome }) else {
                    throw LocalFirstError.refusedChange("Income and expense categories cannot be mixed.")
                }
                let liveChildIDs = liveChildren.map(\.id)
                let allChildIDs = allChildren.map(\.id)
                messages += try categoryBudgetTransferMessages(
                    sourceCategoryIDs: liveChildIDs, destinationCategoryID: destination.id,
                    builder: &builder, in: database, db: db
                )
                messages += try categoryMappingTransferMessages(
                    sourceCategoryIDs: allChildIDs, destinationCategoryID: destination.id,
                    builder: &builder, in: database, db: db
                )
            }
            for child in allChildren {
                messages.append(try builder.tombstone(dataset: "categories", row: child.id))
            }
            messages.append(try builder.tombstone(dataset: "category_groups", row: group.id))
            return messages
        }
    }

    private static func categoryNeedsTransfer(categoryID: String, in database: isolated BudgetDatabase, db: Database) throws -> Bool {
        let transactionColumns = try database.requiredColumns(
            table: "transactions", required: ["category"], db: db
        )
        let transactionCategory = database.quotedIdentifier("category")
        let liveTransactions = database.predicateForLiveRows(columns: transactionColumns, tableAlias: "t")
        let hasTransaction: Bool
        if try database.tableExists("category_mapping", db: db) {
            _ = try database.requiredColumns(
                table: "category_mapping", required: ["id"], db: db
            )
            guard let transferColumn = try database.categoryMappingTransferColumn(db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing category_mapping table")
            }
            hasTransaction = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM transactions t
                        LEFT JOIN category_mapping cm ON cm.id = t.\(transactionCategory)
                        WHERE \(liveTransactions)
                          AND COALESCE(cm.\(database.quotedIdentifier(transferColumn)), t.\(transactionCategory)) = ?
                    )
                    """,
                arguments: [categoryID]
            ) ?? false
        } else {
            hasTransaction = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM transactions t WHERE \(liveTransactions) AND t.\(transactionCategory) = ?)",
                arguments: [categoryID]
            ) ?? false
        }
        if hasTransaction { return true }

        let table = try database.budgetTable(db: db)
        let columns = try database.requiredColumns(
            table: table.rawValue, required: ["month", "category", "amount"], db: db
        )
        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM \(database.quotedIdentifier(table.rawValue))
                    WHERE \(database.quotedIdentifier("category")) = ?
                      AND COALESCE(\(database.quotedIdentifier("amount")), 0) != 0
                      AND \(database.predicateForLiveRows(columns: columns))
                )
                """,
            arguments: [categoryID]
        ) ?? false
    }

    private static func categoryLifecycleRows(
        groupID: String,
        includeTombstones: Bool,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [CategorySQL.CategoryLifecycleCategory] {
        let columns = try database.requiredColumns(
            table: "categories", required: ["id", "name", "is_income", "sort_order", "tombstone"], db: db
        )
        let groupColumn = try database.firstExistingColumn(
            CategoryColumns.groupAliases, in: columns, table: "categories"
        )
        let liveFilter = includeTombstones ? "" : "AND \(database.predicateForLiveRows(columns: columns))"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupColumn) AS group_id, is_income, sort_order
                FROM categories WHERE \(groupColumn) = ? \(liveFilter)
                ORDER BY sort_order, id
                """,
            arguments: [groupID]
        ).map { row in
            guard let id = row["id"] as String?, !id.isEmpty,
                  let rowGroupID = row["group_id"] as String?, !rowGroupID.isEmpty else {
                throw LocalFirstError.invalidLocalWrite("category has no group")
            }
            return CategorySQL.CategoryLifecycleCategory(
                id: id, name: row["name"] ?? "", groupID: rowGroupID,
                isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]), sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"])
            )
        }
    }

    private static func categoryBudgetTransferMessages(
        sourceCategoryIDs: [String],
        destinationCategoryID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard !sourceCategoryIDs.isEmpty else { return [] }
        let table = try database.budgetTable(db: db)
        let columns = try database.requiredColumns(
            table: table.rawValue, required: ["month", "category", "amount"], db: db
        )
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT month, category, amount
                FROM \(database.quotedIdentifier(table.rawValue))
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
        )
        let sourceIDs = Set(sourceCategoryIDs)
        var months = Set<Int>()
        var sourceAmounts: [Int: Int] = [:]
        var destinationAmounts: [Int: Int] = [:]
        for row in rows {
            guard let canonical = YearMonth.canonicalID(SQLiteValueCoercion.lenientString(row["month"])),
                  let categoryID = row["category"] as String? else { continue }
            let monthValue = YearMonth.packedUnchecked(canonical)
            let amount: Int = row["amount"] ?? 0
            months.insert(monthValue)
            if sourceIDs.contains(categoryID) {
                sourceAmounts[monthValue] = try BudgetFinancialCalculation.sum(
                    [sourceAmounts[monthValue, default: 0], amount],
                    table: table
                )
            }
            if categoryID == destinationCategoryID {
                destinationAmounts[monthValue] = try BudgetFinancialCalculation.sum(
                    [destinationAmounts[monthValue, default: 0], amount],
                    table: table
                )
            }
        }

        var messages: [ActualSyncDecodedMessage] = []
        for monthValue in months.sorted() {
            let sourceAmount = sourceAmounts[monthValue, default: 0]
            guard sourceAmount != 0 else { continue }
            messages += try BudgetRowSQL.assignCategoryBudgetMessages(
                categoryID: destinationCategoryID,
                budgeted: try BudgetFinancialCalculation.sum(
                    [destinationAmounts[monthValue, default: 0], sourceAmount],
                    table: table
                ),
                monthValue: monthValue,
                table: table,
                columns: columns,
                builder: &builder,
                in: database,
                db: db
            )
        }
        return messages
    }

    private static func categoryMappingTransferMessages(
        sourceCategoryIDs: [String],
        destinationCategoryID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [ActualSyncDecodedMessage] {
        guard !sourceCategoryIDs.isEmpty else { return [] }
        _ = try database.requiredColumns(
            table: "category_mapping", required: ["id"], db: db
        )
        guard let transferColumn = try database.categoryMappingTransferColumn(db: db) else {
            throw LocalFirstError.invalidLocalWrite("missing category_mapping table")
        }
        var mappingIDs = Set(sourceCategoryIDs)
        for sourceID in sourceCategoryIDs {
            let forwarded = try String.fetchAll(
                db,
                sql: "SELECT id FROM category_mapping WHERE \(database.quotedIdentifier(transferColumn)) = ?",
                arguments: [sourceID]
            )
            mappingIDs.formUnion(forwarded)
        }
        return try mappingIDs.sorted().map {
            try builder.makeMessage(
                dataset: "category_mapping", row: $0, column: transferColumn,
                value: .string(destinationCategoryID)
            )
        }
    }
}
