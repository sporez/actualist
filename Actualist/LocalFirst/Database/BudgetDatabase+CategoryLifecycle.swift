import Foundation
import GRDB

extension BudgetDatabase {
    func createCategoryMessages(
        categoryID: String,
        name: String,
        groupID: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try validatedCategoryLifecycleID(categoryID, kind: "category")
        let name = try validatedCategoryName(name)
        return try queue.read { db in
            let categoryColumns = try requiredColumns(
                table: "categories",
                required: ["id", "name", "is_income", "sort_order"],
                db: db
            )
            let groupColumn = try firstExistingColumn(
                ["cat_group", "group_id"], in: categoryColumns, table: "categories"
            )
            let mappingColumns = try requiredColumns(
                table: "category_mapping", required: ["id"], db: db
            )
            let transferColumn = try firstExistingColumn(
                ["transferId", "transfer_id"], in: mappingColumns, table: "category_mapping"
            )
            guard !(try rowExists(table: "categories", rowID: id, db: db)) else {
                throw LocalFirstError.invalidLocalWrite("category already exists")
            }
            guard !(try rowExists(table: "category_mapping", rowID: id, db: db)) else {
                throw LocalFirstError.invalidLocalWrite("category mapping already exists")
            }
            let group = try requiredCategoryGroup(groupID, db: db)
            try requireCategoryManagementAllowed(isIncome: group.isIncome, kind: "categories", db: db)
            try rejectDuplicateCategoryName(name, groupID: group.id, excluding: nil, db: db)

            let items = try liveCategoryRows(groupID: group.id, db: db).map {
                ActualSortOrder.Item(id: $0.id, sortOrder: $0.sortOrder)
            }
            let shove = ActualSortOrder.shove(items: items, targetID: items.first?.id)
            var messages = try shove.updates.map {
                try builder.makeMessage(dataset: "categories", row: $0.id, column: "sort_order", value: .double($0.sortOrder))
            }
            messages.append(contentsOf: [
                try builder.makeMessage(dataset: "categories", row: id, column: "name", value: .string(name)),
                try builder.makeMessage(dataset: "categories", row: id, column: groupColumn, value: .string(group.id)),
                try builder.makeMessage(dataset: "categories", row: id, column: "is_income", value: .bool(group.isIncome)),
                try builder.makeMessage(dataset: "categories", row: id, column: "sort_order", value: .double(shove.sortOrder))
            ])
            if categoryColumns.contains("hidden") {
                messages.append(try builder.makeMessage(dataset: "categories", row: id, column: "hidden", value: .bool(false)))
            }
            if categoryColumns.contains("tombstone") {
                messages.append(try builder.makeMessage(dataset: "categories", row: id, column: "tombstone", value: .bool(false)))
            }
            messages.append(try builder.makeMessage(
                dataset: "category_mapping", row: id, column: transferColumn, value: .string(id)
            ))
            return messages
        }
    }

    func createCategoryGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try validatedCategoryLifecycleID(groupID, kind: "category group")
        let name = try validatedCategoryGroupName(name)
        return try queue.read { db in
            let columns = try requiredColumns(
                table: "category_groups",
                required: ["id", "name", "is_income", "sort_order"],
                db: db
            )
            guard !(try rowExists(table: "category_groups", rowID: id, db: db)) else {
                throw LocalFirstError.invalidLocalWrite("category group already exists")
            }
            try rejectDuplicateCategoryGroupName(name, excluding: nil, db: db)
            let items = try liveCategoryGroupRows(db: db).map {
                ActualSortOrder.Item(id: $0.id, sortOrder: $0.sortOrder)
            }
            let sortOrder = ActualSortOrder.shove(items: items, targetID: nil).sortOrder
            var messages = [
                try builder.makeMessage(dataset: "category_groups", row: id, column: "name", value: .string(name)),
                try builder.makeMessage(dataset: "category_groups", row: id, column: "is_income", value: .bool(false)),
                try builder.makeMessage(dataset: "category_groups", row: id, column: "sort_order", value: .double(sortOrder))
            ]
            if columns.contains("hidden") {
                messages.append(try builder.makeMessage(dataset: "category_groups", row: id, column: "hidden", value: .bool(false)))
            }
            if columns.contains("tombstone") {
                messages.append(try builder.makeMessage(dataset: "category_groups", row: id, column: "tombstone", value: .bool(false)))
            }
            return messages
        }
    }

    func renameCategoryMessages(
        categoryID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let name = try validatedCategoryName(name)
        return try queue.read { db in
            let category = try requiredCategory(categoryID, db: db)
            try requireCategoryManagementAllowed(isIncome: category.isIncome, kind: "categories", db: db)
            guard category.name != name else { return [] }
            try rejectDuplicateCategoryName(name, groupID: category.groupID, excluding: category.id, db: db)
            return [try builder.makeMessage(dataset: "categories", row: category.id, column: "name", value: .string(name))]
        }
    }

    func renameCategoryGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let name = try validatedCategoryGroupName(name)
        return try queue.read { db in
            let group = try requiredCategoryGroup(groupID, db: db)
            try requireCategoryManagementAllowed(isIncome: group.isIncome, kind: "groups", db: db)
            guard group.name != name else { return [] }
            try rejectDuplicateCategoryGroupName(name, excluding: group.id, db: db)
            return [try builder.makeMessage(dataset: "category_groups", row: group.id, column: "name", value: .string(name))]
        }
    }

    func applyCategoryOutlineMessages(
        _ command: BudgetCategoryOutlineCommand,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        try queue.read { db in
            let categoryColumns = try requiredColumns(
                table: "categories", required: ["id", "name", "is_income", "sort_order"], db: db
            )
            let groupColumn = try firstExistingColumn(
                ["cat_group", "group_id"], in: categoryColumns, table: "categories"
            )
            let allGroups = try liveCategoryGroupRows(db: db)
            let allCategories = try liveCategoryRows(groupID: nil, db: db)
            let isTracking = try isTrackingBudget(db: db)
            let managedGroups = isTracking ? allGroups : allGroups.filter { !$0.isIncome }
            let managedCategories = isTracking ? allCategories : allCategories.filter { !$0.isIncome }

            let desiredGroupIDs = command.groups.map(\.id)
            let desiredCategoryIDs = command.groups.flatMap(\.categoryIDs)
            guard Set(desiredGroupIDs).count == desiredGroupIDs.count,
                  Set(desiredCategoryIDs).count == desiredCategoryIDs.count,
                  Set(desiredGroupIDs) == Set(managedGroups.map(\.id)),
                  Set(desiredCategoryIDs) == Set(managedCategories.map(\.id)) else {
                throw LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")
            }

            let groupsByID = Dictionary(uniqueKeysWithValues: allGroups.map { ($0.id, $0) })
            let categoriesByID = Dictionary(uniqueKeysWithValues: allCategories.map { ($0.id, $0) })
            let existingKinds = managedGroups.map(\.isIncome)
            let desiredKinds = try desiredGroupIDs.map { id in
                guard let group = groupsByID[id] else {
                    throw LocalFirstError.invalidLocalWrite("the category outline changed before it could be saved")
                }
                return group.isIncome
            }
            guard existingKinds == desiredKinds else {
                throw LocalFirstError.invalidLocalWrite("income and expense groups cannot be mixed")
            }

            for desiredGroup in command.groups {
                guard let group = groupsByID[desiredGroup.id] else { continue }
                var names = Set<String>()
                for categoryID in desiredGroup.categoryIDs {
                    guard let category = categoriesByID[categoryID] else { continue }
                    guard category.isIncome == group.isIncome else {
                        throw LocalFirstError.invalidLocalWrite("income and expense categories cannot be mixed")
                    }
                    let folded = category.name.lowercased()
                    guard names.insert(folded).inserted else {
                        throw LocalFirstError.invalidLocalWrite("A category with the name \(category.name) already exists.")
                    }
                }
            }

            var messages: [ActualSyncDecodedMessage] = []
            if desiredGroupIDs != managedGroups.map(\.id) {
                for (index, id) in desiredGroupIDs.enumerated() {
                    let sortOrder = Double(index + 1) * ActualSortOrder.increment
                    if groupsByID[id]?.sortOrder != sortOrder {
                        messages.append(try builder.makeMessage(
                            dataset: "category_groups", row: id, column: "sort_order", value: .double(sortOrder)
                        ))
                    }
                }
            }

            let existingByGroup = Dictionary(grouping: managedCategories, by: \.groupID)
                .mapValues { $0.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }.map(\.id) }
            let affectedGroupIDs = Set(command.groups.compactMap { group in
                existingByGroup[group.id, default: []] == group.categoryIDs ? nil : group.id
            })

            for group in command.groups where affectedGroupIDs.contains(group.id) {
                for (index, categoryID) in group.categoryIDs.enumerated() {
                    guard let category = categoriesByID[categoryID] else { continue }
                    let sortOrder = Double(index + 1) * ActualSortOrder.increment
                    if category.sortOrder != sortOrder {
                        messages.append(try builder.makeMessage(
                            dataset: "categories", row: categoryID, column: "sort_order", value: .double(sortOrder)
                        ))
                    }
                    if category.groupID != group.id {
                        messages.append(try builder.makeMessage(
                            dataset: "categories", row: categoryID, column: groupColumn, value: .string(group.id)
                        ))
                    }
                }
            }
            return messages
        }
    }
}

private extension BudgetDatabase {
    struct CategoryLifecycleGroup {
        let id: String
        let name: String
        let isIncome: Bool
        let sortOrder: Double
    }

    struct CategoryLifecycleCategory {
        let id: String
        let name: String
        let groupID: String
        let isIncome: Bool
        let sortOrder: Double
    }

    func validatedCategoryLifecycleID(_ id: String, kind: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalFirstError.invalidLocalWrite("missing \(kind)") }
        return trimmed
    }

    func validatedCategoryName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalFirstError.invalidLocalWrite("category name cannot be empty") }
        return trimmed
    }

    func validatedCategoryGroupName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalFirstError.invalidLocalWrite("category group name cannot be empty") }
        return trimmed
    }

    func requireCategoryManagementAllowed(isIncome: Bool, kind: String, db: Database) throws {
        let isTracking = try isTrackingBudget(db: db)
        if isIncome && !isTracking {
            throw LocalFirstError.invalidLocalWrite("income \(kind) cannot be managed in an envelope budget")
        }
    }

    func requiredCategoryGroup(_ id: String, db: Database) throws -> CategoryLifecycleGroup {
        let columns = try requiredColumns(
            table: "category_groups", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, name, is_income, sort_order
                FROM category_groups WHERE id = ? AND \(predicateForLiveRows(columns: columns)) LIMIT 1
                """,
            arguments: [id]
        ) else { throw LocalFirstError.invalidLocalWrite("category group no longer exists") }
        return CategoryLifecycleGroup(
            id: row["id"] ?? id, name: row["name"] ?? "",
            isIncome: flexibleBool(row["is_income"]),
            sortOrder: flexibleDouble(row["sort_order"])
        )
    }

    func requiredCategory(_ id: String, db: Database) throws -> CategoryLifecycleCategory {
        let columns = try requiredColumns(
            table: "categories", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        let groupColumn = try firstExistingColumn(["cat_group", "group_id"], in: columns, table: "categories")
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, name, \(groupColumn) AS group_id, is_income, sort_order
                FROM categories WHERE id = ? AND \(predicateForLiveRows(columns: columns)) LIMIT 1
                """,
            arguments: [id]
        ) else { throw LocalFirstError.invalidLocalWrite("category no longer exists") }
        guard let groupID = row["group_id"] as String? else {
            throw LocalFirstError.invalidLocalWrite("category has no group")
        }
        return CategoryLifecycleCategory(
            id: row["id"] ?? id, name: row["name"] ?? "", groupID: groupID,
            isIncome: flexibleBool(row["is_income"]), sortOrder: flexibleDouble(row["sort_order"])
        )
    }

    func liveCategoryGroupRows(db: Database) throws -> [CategoryLifecycleGroup] {
        let columns = try requiredColumns(
            table: "category_groups", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, is_income, sort_order
                FROM category_groups WHERE \(predicateForLiveRows(columns: columns)) ORDER BY sort_order, id
                """
        ).map { row in
            guard let id = row["id"] as String?, !id.isEmpty else {
                throw LocalFirstError.invalidLocalWrite("category group has no id")
            }
            return CategoryLifecycleGroup(
                id: id, name: row["name"] ?? "", isIncome: flexibleBool(row["is_income"]),
                sortOrder: flexibleDouble(row["sort_order"])
            )
        }
    }

    func liveCategoryRows(groupID: String?, db: Database) throws -> [CategoryLifecycleCategory] {
        let columns = try requiredColumns(
            table: "categories", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        let groupColumn = try firstExistingColumn(["cat_group", "group_id"], in: columns, table: "categories")
        let filter = groupID == nil ? "" : "AND \(groupColumn) = ?"
        let arguments = groupID.map { StatementArguments([$0]) } ?? StatementArguments()
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupColumn) AS group_id, is_income, sort_order
                FROM categories WHERE \(predicateForLiveRows(columns: columns)) \(filter)
                ORDER BY sort_order, id
                """,
            arguments: arguments
        ).map { row in
            guard let id = row["id"] as String?, !id.isEmpty,
                  let groupID = row["group_id"] as String?, !groupID.isEmpty else {
                throw LocalFirstError.invalidLocalWrite("category has no group")
            }
            return CategoryLifecycleCategory(
                id: id, name: row["name"] ?? "", groupID: groupID,
                isIncome: flexibleBool(row["is_income"]), sortOrder: flexibleDouble(row["sort_order"])
            )
        }
    }

    func rejectDuplicateCategoryName(_ name: String, groupID: String, excluding id: String?, db: Database) throws {
        let columns = try requiredColumns(table: "categories", required: ["id", "name"], db: db)
        let groupColumn = try firstExistingColumn(["cat_group", "group_id"], in: columns, table: "categories")
        var arguments: StatementArguments = [name, groupID]
        let exclusion: String
        if let id { exclusion = "AND id <> ?"; arguments += [id] } else { exclusion = "" }
        if let existing = try String.fetchOne(
            db,
            sql: """
                SELECT name FROM categories
                WHERE name = ? COLLATE NOCASE AND \(groupColumn) = ?
                  AND \(predicateForLiveRows(columns: columns)) \(exclusion) LIMIT 1
                """,
            arguments: arguments
        ) {
            throw LocalFirstError.invalidLocalWrite("A category with the name \(existing) already exists.")
        }
    }

    func rejectDuplicateCategoryGroupName(_ name: String, excluding id: String?, db: Database) throws {
        let columns = try requiredColumns(table: "category_groups", required: ["id", "name"], db: db)
        var arguments: StatementArguments = [name]
        let exclusion: String
        if let id { exclusion = "AND id <> ?"; arguments += [id] } else { exclusion = "" }
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT name, \(column("hidden", fallback: "0", columns: columns)) AS hidden
                FROM category_groups WHERE name = ? COLLATE NOCASE
                  AND \(predicateForLiveRows(columns: columns)) \(exclusion) LIMIT 1
                """,
            arguments: arguments
        ) {
            let prefix = flexibleBool(row["hidden"]) ? "A hidden category group" : "A category group"
            throw LocalFirstError.invalidLocalWrite("\(prefix) with the name \(row["name"] as String? ?? name) already exists.")
        }
    }
}
