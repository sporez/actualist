import Foundation
import GRDB

enum CategorySQL {
    static func fetchCategories(in database: isolated BudgetDatabase) throws -> [ActualCategory] {
        try database.queue.read { db in
            guard try database.tableExists("categories", db: db) else {
                return []
            }

            let columns = try database.columnSet(for: "categories", db: db)
            let groupID = database.column("cat_group", fallback: database.column("group_id", fallback: "NULL", columns: columns), columns: columns)
            let hidden = database.column("hidden", fallback: "0", columns: columns)
            let isIncome = database.column("is_income", fallback: "0", columns: columns)
            let order = columns.contains("sort_order") ? "sort_order, lower(name)" : "lower(name)"
            let sql = """
                SELECT id, name, \(isIncome) AS is_income, \(hidden) AS hidden, \(groupID) AS group_id
                FROM categories
                WHERE \(database.predicateForLiveRows(columns: columns))
                ORDER BY \(order)
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                ActualCategory(
                    id: row["id"],
                    name: row["name"] ?? "",
                    isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                    hidden: SQLiteValueCoercion.lenientBool(row["hidden"]),
                    groupID: row["group_id"]
                )
            }
        }
    }

    static func createCategoryMessages(
        categoryID: String,
        name: String,
        groupID: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try validatedCategoryLifecycleID(categoryID, kind: "category")
        let name = try EntityName.validatedName(name, label: "category")
        return try database.queue.read { db in
            let categoryColumns = try database.requiredColumns(
                table: "categories",
                required: ["id", "name", "is_income", "sort_order"],
                db: db
            )
            let groupColumn = try database.firstExistingColumn(
                CategoryColumns.groupAliases, in: categoryColumns, table: "categories"
            )
            _ = try database.requiredColumns(
                table: "category_mapping", required: ["id"], db: db
            )
            guard let transferColumn = try database.categoryMappingTransferColumn(db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing category_mapping table")
            }
            guard !(try database.rowExists(table: "categories", rowID: id, db: db)) else {
                throw LocalFirstError.invalidLocalWrite("category already exists")
            }
            guard !(try database.rowExists(table: "category_mapping", rowID: id, db: db)) else {
                throw LocalFirstError.invalidLocalWrite("category mapping already exists")
            }
            let group = try requiredCategoryGroup(groupID, in: database, db: db)
            try requireCategoryManagementAllowed(isIncome: group.isIncome, kind: "categories", in: database, db: db)
            try rejectDuplicateCategoryName(name, groupID: group.id, excluding: nil, in: database, db: db)

            let items = try liveCategoryRows(groupID: group.id, in: database, db: db).map {
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
            messages.append(try builder.makeMessage(
                dataset: "category_mapping", row: id, column: transferColumn, value: .string(id)
            ))
            return messages
        }
    }

    static func createCategoryGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let id = try validatedCategoryLifecycleID(groupID, kind: "category group")
        let name = try EntityName.validatedName(name, label: "category group")
        return try database.queue.read { db in
            let columns = try database.requiredColumns(
                table: "category_groups",
                required: ["id", "name", "is_income", "sort_order"],
                db: db
            )
            guard !(try database.rowExists(table: "category_groups", rowID: id, db: db)) else {
                throw LocalFirstError.invalidLocalWrite("category group already exists")
            }
            try rejectDuplicateCategoryGroupName(name, excluding: nil, in: database, db: db)
            let items = try liveCategoryGroupRows(in: database, db: db).map {
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
            return messages
        }
    }

    static func renameCategoryMessages(
        categoryID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let name = try EntityName.validatedName(name, label: "category")
        return try database.queue.read { db in
            let category = try requiredCategory(categoryID, in: database, db: db)
            try requireCategoryManagementAllowed(isIncome: category.isIncome, kind: "categories", in: database, db: db)
            guard category.name != name else { return [] }
            try rejectDuplicateCategoryName(name, groupID: category.groupID, excluding: category.id, in: database, db: db)
            return [try builder.makeMessage(dataset: "categories", row: category.id, column: "name", value: .string(name))]
        }
    }

    static func renameCategoryGroupMessages(
        groupID: String,
        name: String,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let name = try EntityName.validatedName(name, label: "category group")
        return try database.queue.read { db in
            let group = try requiredCategoryGroup(groupID, in: database, db: db)
            try requireCategoryManagementAllowed(isIncome: group.isIncome, kind: "groups", in: database, db: db)
            guard group.name != name else { return [] }
            try rejectDuplicateCategoryGroupName(name, excluding: group.id, in: database, db: db)
            return [try builder.makeMessage(dataset: "category_groups", row: group.id, column: "name", value: .string(name))]
        }
    }

    static func applyCategoryOutlineMessages(
        _ command: BudgetCategoryOutlineCommand,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        try database.queue.read { db in
            let categoryColumns = try database.requiredColumns(
                table: "categories", required: ["id", "name", "is_income", "sort_order"], db: db
            )
            let groupColumn = try database.firstExistingColumn(
                CategoryColumns.groupAliases, in: categoryColumns, table: "categories"
            )
            let allGroups = try liveCategoryGroupRows(in: database, db: db)
            let allCategories = try liveCategoryRows(groupID: nil, in: database, db: db)
            let isTracking = try database.isTrackingBudget(db: db)
            let managedGroups = isTracking ? allGroups : allGroups.filter { !$0.isIncome }
            let managedCategories = isTracking ? allCategories : allCategories.filter { !$0.isIncome }

            let desiredGroupIDs = command.groups.map(\.id)
            let desiredCategoryIDs = command.groups.flatMap(\.categoryIDs)
            guard Set(desiredGroupIDs).count == desiredGroupIDs.count,
                  Set(desiredCategoryIDs).count == desiredCategoryIDs.count,
                  Set(desiredGroupIDs) == Set(managedGroups.map(\.id)),
                  Set(desiredCategoryIDs) == Set(managedCategories.map(\.id)) else {
                throw LocalFirstError.refusedChange("Your categories changed before this could be saved. Try again.")
            }

            let groupsByID = Dictionary(uniqueKeysWithValues: allGroups.map { ($0.id, $0) })
            let categoriesByID = Dictionary(uniqueKeysWithValues: allCategories.map { ($0.id, $0) })
            let existingKinds = managedGroups.map(\.isIncome)
            let desiredKinds = try desiredGroupIDs.map { id in
                guard let group = groupsByID[id] else {
                    throw LocalFirstError.refusedChange("Your categories changed before this could be saved. Try again.")
                }
                return group.isIncome
            }
            guard existingKinds == desiredKinds else {
                throw LocalFirstError.refusedChange("Income and expense groups cannot be mixed.")
            }

            for desiredGroup in command.groups {
                guard let group = groupsByID[desiredGroup.id] else { continue }
                var names = Set<String>()
                for categoryID in desiredGroup.categoryIDs {
                    guard let category = categoriesByID[categoryID] else { continue }
                    guard category.isIncome == group.isIncome else {
                        throw LocalFirstError.refusedChange("Income and expense categories cannot be mixed.")
                    }
                    let folded = category.name.lowercased()
                    guard names.insert(folded).inserted else {
                        throw LocalFirstError.refusedChange("A category with the name \(category.name) already exists.")
                    }
                }
            }

            let replay = try CategoryOutlineMoveReplay(
                groups: allGroups, categories: allCategories, moves: command.moves
            )
            var messages: [ActualSyncDecodedMessage] = []
            for (id, sortOrder) in replay.changedGroupSortOrders where groupsByID[id]?.sortOrder != sortOrder {
                messages.append(try builder.makeMessage(
                    dataset: "category_groups", row: id, column: "sort_order", value: .double(sortOrder)
                ))
            }
            for (id, state) in replay.changedCategories {
                guard let stored = categoriesByID[id] else { continue }
                if stored.sortOrder != state.sortOrder {
                    messages.append(try builder.makeMessage(
                        dataset: "categories", row: id, column: "sort_order", value: .double(state.sortOrder)
                    ))
                }
                if stored.groupID != state.groupID {
                    messages.append(try builder.makeMessage(
                        dataset: "categories", row: id, column: groupColumn, value: .string(state.groupID)
                    ))
                }
            }
            return messages
        }
    }

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

    static func validatedCategoryLifecycleID(_ id: String, kind: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalFirstError.invalidLocalWrite("missing \(kind)") }
        return trimmed
    }

    static func requireCategoryManagementAllowed(isIncome: Bool, kind: String, in database: isolated BudgetDatabase, db: Database) throws {
        let isTracking = try database.isTrackingBudget(db: db)
        if isIncome && !isTracking {
            throw LocalFirstError.invalidLocalWrite("income \(kind) cannot be managed in an envelope budget")
        }
    }

    static func requiredCategoryGroup(_ id: String, in database: isolated BudgetDatabase, db: Database) throws -> CategoryLifecycleGroup {
        let columns = try database.requiredColumns(
            table: "category_groups", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, name, is_income, sort_order
                FROM category_groups WHERE id = ? AND \(database.predicateForLiveRows(columns: columns)) LIMIT 1
                """,
            arguments: [id]
        ) else { throw LocalFirstError.invalidLocalWrite("category group no longer exists") }
        return CategoryLifecycleGroup(
            id: row["id"] ?? id, name: row["name"] ?? "",
            isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
            sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"])
        )
    }

    static func requiredCategory(_ id: String, in database: isolated BudgetDatabase, db: Database) throws -> CategoryLifecycleCategory {
        let columns = try database.requiredColumns(
            table: "categories", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        let groupColumn = try database.firstExistingColumn(CategoryColumns.groupAliases, in: columns, table: "categories")
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, name, \(groupColumn) AS group_id, is_income, sort_order
                FROM categories WHERE id = ? AND \(database.predicateForLiveRows(columns: columns)) LIMIT 1
                """,
            arguments: [id]
        ) else { throw LocalFirstError.invalidLocalWrite("category no longer exists") }
        guard let groupID = row["group_id"] as String? else {
            throw LocalFirstError.invalidLocalWrite("category has no group")
        }
        return CategoryLifecycleCategory(
            id: row["id"] ?? id, name: row["name"] ?? "", groupID: groupID,
            isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]), sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"])
        )
    }

    static func liveCategoryRows(groupID: String?, in database: isolated BudgetDatabase, db: Database) throws -> [CategoryLifecycleCategory] {
        let columns = try database.requiredColumns(
            table: "categories", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        let groupColumn = try database.firstExistingColumn(CategoryColumns.groupAliases, in: columns, table: "categories")
        let filter = groupID == nil ? "" : "AND \(groupColumn) = ?"
        let arguments = groupID.map { StatementArguments([$0]) } ?? StatementArguments()
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, \(groupColumn) AS group_id, is_income, sort_order
                FROM categories WHERE \(database.predicateForLiveRows(columns: columns)) \(filter)
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
                isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]), sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"])
            )
        }
    }

    private static func liveCategoryGroupRows(in database: isolated BudgetDatabase, db: Database) throws -> [CategoryLifecycleGroup] {
        let columns = try database.requiredColumns(
            table: "category_groups", required: ["id", "name", "is_income", "sort_order"], db: db
        )
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name, is_income, sort_order
                FROM category_groups WHERE \(database.predicateForLiveRows(columns: columns)) ORDER BY sort_order, id
                """
        ).map { row in
            guard let id = row["id"] as String?, !id.isEmpty else {
                throw LocalFirstError.invalidLocalWrite("category group has no id")
            }
            return CategoryLifecycleGroup(
                id: id, name: row["name"] ?? "", isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                sortOrder: SQLiteValueCoercion.lenientDouble(row["sort_order"])
            )
        }
    }

    private static func rejectDuplicateCategoryName(_ name: String, groupID: String, excluding id: String?, in database: isolated BudgetDatabase, db: Database) throws {
        let columns = try database.requiredColumns(table: "categories", required: ["id", "name"], db: db)
        let groupColumn = try database.firstExistingColumn(CategoryColumns.groupAliases, in: columns, table: "categories")
        var arguments: StatementArguments = [name, groupID]
        let exclusion: String
        if let id { exclusion = "AND id <> ?"; arguments += [id] } else { exclusion = "" }
        if let existing = try String.fetchOne(
            db,
            sql: """
                SELECT name FROM categories
                WHERE name = ? COLLATE NOCASE AND \(groupColumn) = ?
                  AND \(database.predicateForLiveRows(columns: columns)) \(exclusion) LIMIT 1
                """,
            arguments: arguments
        ) {
            throw LocalFirstError.refusedChange("A category with the name \(existing) already exists.")
        }
    }

    private static func rejectDuplicateCategoryGroupName(_ name: String, excluding id: String?, in database: isolated BudgetDatabase, db: Database) throws {
        let columns = try database.requiredColumns(table: "category_groups", required: ["id", "name"], db: db)
        var arguments: StatementArguments = [name]
        let exclusion: String
        if let id { exclusion = "AND id <> ?"; arguments += [id] } else { exclusion = "" }
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT name, \(database.column("hidden", fallback: "0", columns: columns)) AS hidden
                FROM category_groups WHERE name = ? COLLATE NOCASE
                  AND \(database.predicateForLiveRows(columns: columns)) \(exclusion) LIMIT 1
                """,
            arguments: arguments
        ) {
            let prefix = SQLiteValueCoercion.lenientBool(row["hidden"]) ? "A hidden category group" : "A category group"
            throw LocalFirstError.refusedChange("\(prefix) with the name \(row["name"] as String? ?? name) already exists.")
        }
    }

    static func setCategoryHiddenMessages(
        categoryID: String,
        hidden: Bool,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try database.queue.read { db in
            let categoryColumns = try database.requiredColumns(
                table: "categories",
                required: ["hidden"],
                db: db
            )
            let groupColumn = try database.firstExistingColumn(
                CategoryColumns.groupAliases,
                in: categoryColumns,
                table: "categories"
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, hidden, \(groupColumn) AS group_id
                    FROM categories
                    WHERE id = ? AND \(database.predicateForLiveRows(columns: categoryColumns))
                    LIMIT 1
                    """,
                arguments: [trimmedID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            let groupID = row["group_id"] as String?
            if let groupID, try database.tableExists("category_groups", db: db) {
                let groupColumns = try database.columnSet(for: "category_groups", db: db)
                if groupColumns.contains("hidden"),
                   let groupRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT hidden
                        FROM category_groups
                        WHERE id = ? AND \(database.predicateForLiveRows(columns: groupColumns))
                        LIMIT 1
                        """,
                    arguments: [groupID]
                   ),
                   SQLiteValueCoercion.lenientBool(groupRow["hidden"]) {
                    throw LocalFirstError.refusedChange("This category is in a hidden group. Show the group before changing it.")
                }
            }

            if SQLiteValueCoercion.lenientBool(row["hidden"]) == hidden {
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

    static func setCategoryGroupHiddenMessages(
        groupID: String,
        hidden: Bool,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category group")
        }

        return try database.queue.read { db in
            let groupColumns = try database.requiredColumns(
                table: "category_groups",
                required: ["hidden"],
                db: db
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, hidden, \(database.column("is_income", fallback: "0", columns: groupColumns)) AS is_income
                    FROM category_groups
                    WHERE id = ? AND \(database.predicateForLiveRows(columns: groupColumns))
                    LIMIT 1
                    """,
                arguments: [trimmedID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category group")
            }

            if SQLiteValueCoercion.lenientBool(row["is_income"]) {
                throw LocalFirstError.refusedChange("Income groups cannot be hidden.")
            }
            if SQLiteValueCoercion.lenientBool(row["hidden"]) == hidden {
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

/// Replays reorder drags in order on in-memory copies of the live rows, as Actual's `moveCategory` and
/// `moveCategoryGroup` do for each drag it receives (`shoveSortOrders` over the live rows by
/// `sort_order, id`). The caller writes only the cells whose final value differs from the stored row.
struct CategoryOutlineMoveReplay {
    struct CategoryState: Equatable {
        var sortOrder: Double
        var groupID: String
    }

    private(set) var changedGroupSortOrders: [(id: String, sortOrder: Double)] = []
    private(set) var changedCategories: [(id: String, state: CategoryState)] = []

    init(
        groups: [CategorySQL.CategoryLifecycleGroup],
        categories: [CategorySQL.CategoryLifecycleCategory],
        moves: [BudgetCategoryOutlineCommand.Move]
    ) throws {
        var groupOrders = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.sortOrder) })
        var categoryStates = Dictionary(uniqueKeysWithValues: categories.map {
            ($0.id, CategoryState(sortOrder: $0.sortOrder, groupID: $0.groupID))
        })
        var touchedGroups: [String] = []
        var touchedCategories: [String] = []
        let changed = LocalFirstError.refusedChange("Your categories changed before this could be saved. Try again.")

        for move in moves {
            switch move {
            case .category(let id, let toGroupID, let beforeCategoryID):
                guard categoryStates[id] != nil, groupOrders[toGroupID] != nil else { throw changed }
                let items = categoryStates
                    .filter { $0.value.groupID == toGroupID }
                    .map { ActualSortOrder.Item(id: $0.key, sortOrder: $0.value.sortOrder) }
                    .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
                let shove = ActualSortOrder.shove(items: items, targetID: beforeCategoryID)
                for update in shove.updates {
                    categoryStates[update.id]?.sortOrder = update.sortOrder
                    Self.note(update.id, in: &touchedCategories)
                }
                categoryStates[id] = CategoryState(sortOrder: shove.sortOrder, groupID: toGroupID)
                Self.note(id, in: &touchedCategories)
            case .group(let id, let beforeGroupID):
                guard groupOrders[id] != nil else { throw changed }
                let items = groupOrders
                    .map { ActualSortOrder.Item(id: $0.key, sortOrder: $0.value) }
                    .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
                let shove = ActualSortOrder.shove(items: items, targetID: beforeGroupID)
                for update in shove.updates {
                    groupOrders[update.id] = update.sortOrder
                    Self.note(update.id, in: &touchedGroups)
                }
                groupOrders[id] = shove.sortOrder
                Self.note(id, in: &touchedGroups)
            }
        }
        changedGroupSortOrders = touchedGroups.compactMap { id in groupOrders[id].map { (id, $0) } }
        changedCategories = touchedCategories.compactMap { id in categoryStates[id].map { (id, $0) } }
    }

    private static func note(_ id: String, in touched: inout [String]) {
        if !touched.contains(id) { touched.append(id) }
    }
}
