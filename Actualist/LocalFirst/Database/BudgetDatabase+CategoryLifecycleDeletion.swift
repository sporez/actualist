import Foundation
import GRDB

extension BudgetDatabase {
    func categoryNeedsTransfer(categoryID: String) throws -> Bool {
        let id = try validatedCategoryLifecycleID(categoryID, kind: "category")
        return try queue.read { db in
            _ = try requiredCategory(id, db: db)
            return try categoryNeedsTransfer(categoryID: id, db: db)
        }
    }

    func deleteCategoryMessages(
        categoryID: String,
        transferCategoryID: String?,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try validatedCategoryLifecycleID(categoryID, kind: "category")
        let transferID = try transferCategoryID.map {
            try validatedCategoryLifecycleID($0, kind: "transfer category")
        }
        return try queue.read { db in
            let category = try requiredCategory(id, db: db)
            try requireCategoryManagementAllowed(isIncome: category.isIncome, kind: "categories", db: db)
            _ = try requiredColumns(table: "categories", required: ["tombstone"], db: db)
            if transferID == nil, try categoryNeedsTransfer(categoryID: id, db: db) {
                throw LocalFirstError.invalidLocalWrite("category requires a transfer destination")
            }

            var messages: [ActualSyncDecodedMessage] = []
            if let transferID {
                let destination = try requiredCategory(transferID, db: db)
                guard destination.id != category.id else {
                    throw LocalFirstError.invalidLocalWrite("a category cannot transfer to itself")
                }
                guard destination.isIncome == category.isIncome else {
                    throw LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")
                }
                if !category.isIncome {
                    messages += try categoryBudgetTransferMessages(
                        sourceCategoryIDs: [category.id], destinationCategoryID: destination.id,
                        db: db, builder: &builder
                    )
                }
                messages += try categoryMappingTransferMessages(
                    sourceCategoryIDs: [category.id], destinationCategoryID: destination.id,
                    db: db, builder: &builder
                )
            }
            messages.append(try builder.makeMessage(
                dataset: "categories", row: category.id, column: "tombstone", value: .bool(true)
            ))
            return messages
        }
    }

    func deleteCategoryGroupMessages(
        groupID: String,
        transferCategoryID: String?,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try validatedCategoryLifecycleID(groupID, kind: "category group")
        let transferID = try transferCategoryID.map {
            try validatedCategoryLifecycleID($0, kind: "transfer category")
        }
        return try queue.read { db in
            let group = try requiredCategoryGroup(id, db: db)
            try requireCategoryManagementAllowed(isIncome: group.isIncome, kind: "groups", db: db)
            _ = try requiredColumns(table: "category_groups", required: ["tombstone"], db: db)
            let allChildren = try categoryLifecycleRows(groupID: group.id, includeTombstones: true, db: db)
            let liveChildren = try liveCategoryRows(groupID: group.id, db: db)
            if transferID == nil,
               try liveChildren.contains(where: { try categoryNeedsTransfer(categoryID: $0.id, db: db) }) {
                throw LocalFirstError.invalidLocalWrite("category group requires a transfer destination")
            }

            var messages: [ActualSyncDecodedMessage] = []
            if let transferID {
                let destination = try requiredCategory(transferID, db: db)
                guard destination.groupID != group.id else {
                    throw LocalFirstError.invalidLocalWrite("a category group cannot transfer within itself")
                }
                guard destination.isIncome == group.isIncome else {
                    throw LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")
                }
                guard allChildren.allSatisfy({ $0.isIncome == destination.isIncome }) else {
                    throw LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")
                }
                let childIDs = allChildren.map(\.id)
                messages += try categoryBudgetTransferMessages(
                    sourceCategoryIDs: childIDs, destinationCategoryID: destination.id,
                    db: db, builder: &builder
                )
                messages += try categoryMappingTransferMessages(
                    sourceCategoryIDs: childIDs, destinationCategoryID: destination.id,
                    db: db, builder: &builder
                )
            }
            for child in allChildren {
                messages.append(try builder.makeMessage(
                    dataset: "categories", row: child.id, column: "tombstone", value: .bool(true)
                ))
            }
            messages.append(try builder.makeMessage(
                dataset: "category_groups", row: group.id, column: "tombstone", value: .bool(true)
            ))
            return messages
        }
    }
}

private extension BudgetDatabase {
    func categoryNeedsTransfer(categoryID: String, db: Database) throws -> Bool {
        let transactionColumns = try requiredColumns(
            table: "transactions", required: ["category"], db: db
        )
        let transactionCategory = quotedIdentifier("category")
        let liveTransactions = predicateForLiveRows(columns: transactionColumns, tableAlias: "t")
        let hasTransaction: Bool
        if try tableExists("category_mapping", db: db) {
            let mappingColumns = try requiredColumns(
                table: "category_mapping", required: ["id"], db: db
            )
            let transferColumn = try firstExistingColumn(
                ["transferId", "transfer_id"], in: mappingColumns, table: "category_mapping"
            )
            hasTransaction = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM transactions t
                        LEFT JOIN category_mapping cm ON cm.id = t.\(transactionCategory)
                        WHERE \(liveTransactions)
                          AND COALESCE(cm.\(quotedIdentifier(transferColumn)), t.\(transactionCategory)) = ?
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

        let table = try budgetTable(db: db)
        let columns = try requiredColumns(
            table: table.rawValue, required: ["month", "category", "amount"], db: db
        )
        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM \(quotedIdentifier(table.rawValue))
                    WHERE \(quotedIdentifier("category")) = ?
                      AND COALESCE(\(quotedIdentifier("amount")), 0) != 0
                      AND \(predicateForLiveRows(columns: columns))
                )
                """,
            arguments: [categoryID]
        ) ?? false
    }

    func categoryLifecycleRows(
        groupID: String,
        includeTombstones: Bool,
        db: Database
    ) throws -> [CategoryLifecycleCategory] {
        let columns = try requiredColumns(
            table: "categories", required: ["id", "name", "is_income", "sort_order", "tombstone"], db: db
        )
        let groupColumn = try firstExistingColumn(
            ["cat_group", "group_id"], in: columns, table: "categories"
        )
        let liveFilter = includeTombstones ? "" : "AND \(predicateForLiveRows(columns: columns))"
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
            return CategoryLifecycleCategory(
                id: id, name: row["name"] ?? "", groupID: rowGroupID,
                isIncome: flexibleBool(row["is_income"]), sortOrder: flexibleDouble(row["sort_order"])
            )
        }
    }

    func categoryBudgetTransferMessages(
        sourceCategoryIDs: [String],
        destinationCategoryID: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !sourceCategoryIDs.isEmpty else { return [] }
        let table = try budgetTable(db: db)
        let columns = try requiredColumns(
            table: table.rawValue, required: ["month", "category", "amount"], db: db
        )
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT month, category, amount
                FROM \(quotedIdentifier(table.rawValue))
                WHERE \(predicateForLiveRows(columns: columns))
                """
        )
        let sourceIDs = Set(sourceCategoryIDs)
        var months = Set<Int>()
        var sourceAmounts: [Int: Int] = [:]
        var destinationAmounts: [Int: Int] = [:]
        for row in rows {
            guard let canonical = canonicalMonthID(flexibleString(row["month"])),
                  let categoryID = row["category"] as String? else { continue }
            let monthValue = monthInt(canonical)
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
            messages += try assignCategoryBudgetMessages(
                categoryID: destinationCategoryID,
                budgeted: try BudgetFinancialCalculation.sum(
                    [destinationAmounts[monthValue, default: 0], sourceAmount],
                    table: table
                ),
                monthValue: monthValue,
                table: table,
                columns: columns,
                db: db,
                builder: &builder
            )
        }
        return messages
    }

    func categoryMappingTransferMessages(
        sourceCategoryIDs: [String],
        destinationCategoryID: String,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard !sourceCategoryIDs.isEmpty else { return [] }
        let columns = try requiredColumns(
            table: "category_mapping", required: ["id"], db: db
        )
        let transferColumn = try firstExistingColumn(
            ["transferId", "transfer_id"], in: columns, table: "category_mapping"
        )
        var mappingIDs = Set(sourceCategoryIDs)
        for sourceID in sourceCategoryIDs {
            let forwarded = try String.fetchAll(
                db,
                sql: "SELECT id FROM category_mapping WHERE \(quotedIdentifier(transferColumn)) = ?",
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
