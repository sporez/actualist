import Foundation
import GRDB

enum TemplateAuthoringSQL {
    static func categoryTemplateEditorSnapshot(
        categoryID: String,
        now: Date = Date(),
        in database: isolated BudgetDatabase
    ) throws -> BudgetTemplateEditorSnapshot {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try database.queue.read { db in
            guard try database.tableExists("categories", db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            let columns = try database.columnSet(for: "categories", db: db)
            let hasGoalDefColumn = columns.contains("goal_def")
            let hasTemplateSettingsColumn = columns.contains("template_settings")
            let nameSelection = columns.contains("name") ? "name" : "NULL"
            let goalSelection = hasGoalDefColumn ? "goal_def" : "NULL"
            let settingsSelection = hasTemplateSettingsColumn ? "template_settings" : "NULL"

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, \(nameSelection) AS name,
                           \(goalSelection) AS goal_def,
                           \(settingsSelection) AS template_settings
                    FROM categories
                    WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
                    LIMIT 1
                    """,
                arguments: [trimmed]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            let name = (row["name"] as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let goalDefJSON = row["goal_def"] as String?
            let source = templateSource(from: row["template_settings"] as String?)
            let notes = try TemplateCategorySQL.readCategoryNotes(in: database, db: db)
            let note = notes[trimmed] ?? ""
            let noteHasDirectives = !BudgetTemplateNoteParser.directives(in: note).isEmpty
            let isStale = try isStaleNoteManagedTemplate(
                categoryID: trimmed,
                goalDefJSON: goalDefJSON,
                in: database,
                db: db
            )
            let lock = BudgetTemplateCategoryLock.evaluate(
                hasGoalDefColumn: hasGoalDefColumn,
                hasTemplateSettingsColumn: hasTemplateSettingsColumn,
                source: source,
                noteHasDirectives: noteHasDirectives,
                isStale: isStale,
                goalDefJSON: goalDefJSON
            )
            let drafts = BudgetTemplateDefinition.drafts(fromJSON: goalDefJSON, now: now) ?? []
            let authoringContext = try templateEditorAuthoringContext(now: now, in: database, db: db)
            let hasDefinition = BudgetMonthSQL.hasStoredTemplateDefinition(goalDefJSON)
            return BudgetTemplateEditorSnapshot(
                categoryID: trimmed,
                categoryName: name,
                drafts: drafts,
                lock: lock,
                schedules: authoringContext.schedules,
                incomeCategories: authoringContext.incomeCategories,
                currency: try BudgetCurrencySQL.budgetCurrency(in: database, db: db),
                hasDefinition: hasDefinition
            )
        }
    }

    private static func templateEditorIncomeCategories(in database: isolated BudgetDatabase, db: Database) throws -> [BudgetTemplateIncomeOption] {
        let catalog = try TemplateInputSQL.templateIncomeCatalog(in: database, db: db)
        return catalog.incomeCategoryIDsInOrder.compactMap { id in
            guard let name = catalog.incomeCategoryNamesByID[id] else { return nil }
            return BudgetTemplateIncomeOption(
                id: id,
                name: name,
                isAvailable: !catalog.hiddenIncomeCategoryIDs.contains(id)
            )
        }
    }

    private static func templateEditorAuthoringContext(
        now: Date = Date(),
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> BudgetTemplateAuthoringContext {
        BudgetTemplateAuthoringContext(
            today: now,
            schedules: try templateEditorSchedules(in: database, db: db),
            incomeCategories: try templateEditorIncomeCategories(in: database, db: db)
        )
    }

    private static func templateEditorSchedules(in database: isolated BudgetDatabase, db: Database) throws -> [BudgetTemplateScheduleOption] {
        guard try database.tableExists("schedules", db: db) else {
            return []
        }
        let columns = try database.columnSet(for: "schedules", db: db)
        guard columns.contains("name") else {
            return []
        }
        let idSelection = columns.contains("id") ? "id" : "NULL"
        let completedSelection = columns.contains("completed") ? "completed" : "0"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(idSelection) AS id, name, \(completedSelection) AS completed
                FROM schedules
                WHERE name IS NOT NULL
                  AND \(database.predicateForLiveRows(columns: columns))
                """
        )
        var options: [BudgetTemplateScheduleOption] = []
        for row in rows {
            if SQLiteValueCoercion.lenientBool(row["completed"]) {
                continue
            }
            guard let id = row["id"] as String?, !id.isEmpty else {
                continue
            }
            let name = (row["name"] as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                continue
            }
            options.append(BudgetTemplateScheduleOption(id: id, name: name))
        }
        options.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return options
    }

    static func categoryTemplateBrowserSnapshot(
        now: Date = Date(),
        in database: isolated BudgetDatabase
    ) throws -> BudgetTemplateBrowserSnapshot {
        try database.queue.read { db in
            let currency = try BudgetCurrencySQL.budgetCurrency(in: database, db: db)
            let month = YearMonth(date: now).rawValue
            guard try database.tableExists("categories", db: db),
                  try database.tableExists("category_groups", db: db) else {
                return BudgetTemplateBrowserSnapshot(
                    categories: [],
                    currency: currency,
                    month: month
                )
            }

            let groupColumns = try database.columnSet(for: "category_groups", db: db)
            let categoryColumns = try database.columnSet(for: "categories", db: db)
            let hasGoalDefColumn = categoryColumns.contains("goal_def")
            let hasTemplateSettingsColumn = categoryColumns.contains("template_settings")
            let groupHidden = database.column("hidden", fallback: "0", columns: groupColumns)
            let groupIncome = database.column("is_income", fallback: "0", columns: groupColumns)
            let groupOrder = groupColumns.contains("sort_order")
                ? "sort_order, lower(name)"
                : "lower(name)"
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, \(groupIncome) AS is_income, \(groupHidden) AS hidden
                    FROM category_groups
                    WHERE \(database.predicateForLiveRows(columns: groupColumns))
                    ORDER BY \(groupOrder)
                    """
            )

            var groups: [(id: String, name: String, isIncome: Bool, hidden: Bool)] = []
            for groupRow in groupRows {
                let id = (groupRow["id"] as String?) ?? ""
                guard !id.isEmpty else {
                    continue
                }
                groups.append(
                    (
                        id: id,
                        name: (groupRow["name"] as String?) ?? "",
                        isIncome: SQLiteValueCoercion.lenientBool(groupRow["is_income"]),
                        hidden: SQLiteValueCoercion.lenientBool(groupRow["hidden"])
                    )
                )
            }
            let liveGroupIDs = Set(groups.map(\.id))

            let groupColumn = database.column(
                "cat_group",
                fallback: database.column("group_id", fallback: "NULL", columns: categoryColumns),
                columns: categoryColumns
            )
            let categoryHidden = database.column("hidden", fallback: "0", columns: categoryColumns)
            let categoryIncome = database.column("is_income", fallback: "0", columns: categoryColumns)
            let goalSelection = hasGoalDefColumn ? "goal_def" : "NULL"
            let settingsSelection = hasTemplateSettingsColumn ? "template_settings" : "NULL"
            let categoryOrder = categoryColumns.contains("sort_order")
                ? "sort_order, lower(name)"
                : "lower(name)"
            let categoryRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, \(groupColumn) AS group_id,
                           \(categoryIncome) AS is_income, \(categoryHidden) AS hidden,
                           \(goalSelection) AS goal_def,
                           \(settingsSelection) AS template_settings
                    FROM categories
                    WHERE \(database.predicateForLiveRows(columns: categoryColumns))
                    ORDER BY \(categoryOrder)
                    """
            )

            struct RawCategory {
                var id: String
                var name: String
                var groupID: String
                var isIncome: Bool
                var hidden: Bool
                var goalDefJSON: String?
                var source: String?
            }

            var rawByGroup: [String: [RawCategory]] = [:]
            var goalDefsRaw: [String: String] = [:]
            for row in categoryRows {
                let id = (row["id"] as String?) ?? ""
                guard !id.isEmpty else {
                    continue
                }
                let groupID = (row["group_id"] as String?) ?? ""
                guard liveGroupIDs.contains(groupID) else {
                    continue
                }
                let goalDefJSON = row["goal_def"] as String?
                let raw = RawCategory(
                    id: id,
                    name: (row["name"] as String?) ?? "",
                    groupID: groupID,
                    isIncome: SQLiteValueCoercion.lenientBool(row["is_income"]),
                    hidden: SQLiteValueCoercion.lenientBool(row["hidden"]),
                    goalDefJSON: goalDefJSON,
                    source: templateSource(from: row["template_settings"] as String?)
                )
                rawByGroup[groupID, default: []].append(raw)
                if let goalDefJSON {
                    let trimmed = goalDefJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != "null" {
                        goalDefsRaw[id] = trimmed
                    }
                }
            }

            let notes = try TemplateCategorySQL.readCategoryNotes(in: database, db: db)
            var staleIDs = Set<String>()
            for stale in try TemplateCategorySQL.staleNoteManagedTemplateCategories(
                goalDefsRaw: goalDefsRaw,
                in: database,
                db: db
            ) {
                staleIDs.insert(stale.categoryID)
            }

            var categories: [BudgetTemplateBrowserCategory] = []
            for group in groups {
                let members = rawByGroup[group.id] ?? []
                for raw in members {
                    let note = notes[raw.id] ?? ""
                    let lock = BudgetTemplateCategoryLock.evaluate(
                        hasGoalDefColumn: hasGoalDefColumn,
                        hasTemplateSettingsColumn: hasTemplateSettingsColumn,
                        source: raw.source,
                        noteHasDirectives: !BudgetTemplateNoteParser.directives(in: note).isEmpty,
                        isStale: staleIDs.contains(raw.id),
                        goalDefJSON: raw.goalDefJSON
                    )
                    categories.append(
                        BudgetTemplateBrowserCategory(
                            id: raw.id,
                            name: raw.name,
                            groupID: group.id,
                            groupName: group.name,
                            isIncome: raw.isIncome || group.isIncome,
                            isEffectivelyHidden: BudgetCategoryVisibility.isEffectivelyHidden(
                                categoryHidden: raw.hidden,
                                groupHidden: group.hidden
                            ),
                            hasDefinition: BudgetMonthSQL.hasStoredTemplateDefinition(raw.goalDefJSON),
                            drafts: BudgetTemplateDefinition.drafts(
                                fromJSON: raw.goalDefJSON,
                                now: now
                            ) ?? [],
                            lock: lock
                        )
                    )
                }
            }

            return BudgetTemplateBrowserSnapshot(
                categories: categories,
                currency: currency,
                month: month
            )
        }
    }

    static let uiTemplateSettingsJSON = #"{"source":"ui"}"#

    /// CRDT messages that set `categories.goal_def` and
    /// `categories.template_settings.source=ui`. Empty `goalDefJSON` nulls
    /// `goal_def`. Does not apply budgets or write `cleanup_def`.
    static func setCategoryTemplateMessages(
        categoryID: String,
        goalDefJSON: String?,
        builder: inout LocalFirstSyncMessageBuilder,
        in database: isolated BudgetDatabase
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try database.queue.read { db in
            guard try database.tableExists("categories", db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            let columns = try database.columnSet(for: "categories", db: db)
            guard columns.contains("goal_def"), columns.contains("template_settings") else {
                throw LocalFirstError.refusedChange(
                    BudgetTemplateCategoryLock.Reason.missingColumns.testerFacingReason
                )
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, goal_def, template_settings
                    FROM categories
                    WHERE id = ? AND \(database.predicateForLiveRows(columns: columns))
                    LIMIT 1
                    """,
                arguments: [trimmedID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            let currentGoalDef = row["goal_def"] as String?
            let currentSettings = row["template_settings"] as String?
            let source = templateSource(from: currentSettings)
            let notes = try TemplateCategorySQL.readCategoryNotes(in: database, db: db)
            let note = notes[trimmedID] ?? ""
            let noteHasDirectives = !BudgetTemplateNoteParser.directives(in: note).isEmpty
            let isStale = try isStaleNoteManagedTemplate(
                categoryID: trimmedID,
                goalDefJSON: currentGoalDef,
                in: database,
                db: db
            )
            let lock = BudgetTemplateCategoryLock.evaluate(
                hasGoalDefColumn: true,
                hasTemplateSettingsColumn: true,
                source: source,
                noteHasDirectives: noteHasDirectives,
                isStale: isStale,
                goalDefJSON: currentGoalDef
            )
            if case .readOnly(let reason) = lock {
                throw LocalFirstError.refusedChange(reason.testerFacingReason)
            }

            let incomingJSON = normalizedGoalDefJSON(goalDefJSON)
            switch BudgetTemplateDefinition.parseEntries(from: incomingJSON) {
            case .failure:
                throw LocalFirstError.refusedChange(
                    BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
                )
            case .success:
                guard let drafts = BudgetTemplateDefinition.drafts(
                          fromJSON: incomingJSON,
                          now: Date()
                      ),
                      BudgetTemplateAuthoringValidation.isValid(
                          drafts,
                          context: try templateEditorAuthoringContext(in: database, db: db)
                      ) else {
                    throw LocalFirstError.refusedChange(
                        BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
                    )
                }
            }

            let goalValue: LocalFirstSyncValue = incomingJSON.map(LocalFirstSyncValue.string) ?? .null
            var messages: [ActualSyncDecodedMessage] = []
            if !goalDefUnchanged(current: currentGoalDef, incoming: incomingJSON) {
                messages.append(
                    try builder.makeMessage(
                        dataset: "categories",
                        row: trimmedID,
                        column: "goal_def",
                        value: goalValue
                    )
                )
            }
            if source != "ui" {
                messages.append(
                    try builder.makeMessage(
                        dataset: "categories",
                        row: trimmedID,
                        column: "template_settings",
                        value: .string(uiTemplateSettingsJSON)
                    )
                )
            }
            return messages
        }
    }

    private static func isStaleNoteManagedTemplate(
        categoryID: String,
        goalDefJSON: String?,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> Bool {
        guard let goalDefJSON else {
            return false
        }
        let trimmed = goalDefJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else {
            return false
        }
        let stale = try TemplateCategorySQL.staleNoteManagedTemplateCategories(
            goalDefsRaw: [categoryID: trimmed],
            in: database,
            db: db
        )
        return stale.contains { $0.categoryID == categoryID }
    }

    private static func normalizedGoalDefJSON(_ json: String?) -> String? {
        guard let json else {
            return nil
        }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return nil
        }
        switch BudgetTemplateDefinition.parseEntries(from: trimmed) {
        case .success(let entries) where entries.isEmpty:
            return nil
        default:
            return trimmed
        }
    }

    private static func goalDefUnchanged(current: String?, incoming: String?) -> Bool {
        normalizedGoalDefJSON(current) == incoming
    }

    static func templateSource(from raw: String?) -> String? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["source"] as? String else {
            return nil
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
