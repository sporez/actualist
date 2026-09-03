import Foundation
import GRDB

extension BudgetDatabase {
    func categoryTemplateBrowserSnapshot(
        now: Date = Date()
    ) throws -> BudgetTemplateBrowserSnapshot {
        try queue.read { db in
            let currency = try budgetCurrency(db: db)
            let month = YearMonth(date: now).rawValue
            guard try tableExists("categories", db: db),
                  try tableExists("category_groups", db: db) else {
                return BudgetTemplateBrowserSnapshot(
                    categories: [],
                    currency: currency,
                    month: month
                )
            }

            let groupColumns = try columnSet(for: "category_groups", db: db)
            let categoryColumns = try columnSet(for: "categories", db: db)
            let hasGoalDefColumn = categoryColumns.contains("goal_def")
            let hasTemplateSettingsColumn = categoryColumns.contains("template_settings")
            let groupHidden = column("hidden", fallback: "0", columns: groupColumns)
            let groupIncome = column("is_income", fallback: "0", columns: groupColumns)
            let groupOrder = groupColumns.contains("sort_order")
                ? "sort_order, lower(name)"
                : "lower(name)"
            let groupRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, \(groupIncome) AS is_income, \(groupHidden) AS hidden
                    FROM category_groups
                    WHERE \(predicateForLiveRows(columns: groupColumns))
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
                        isIncome: flexibleBool(groupRow["is_income"]),
                        hidden: flexibleBool(groupRow["hidden"])
                    )
                )
            }
            let liveGroupIDs = Set(groups.map(\.id))

            let groupColumn = column(
                "cat_group",
                fallback: column("group_id", fallback: "NULL", columns: categoryColumns),
                columns: categoryColumns
            )
            let categoryHidden = column("hidden", fallback: "0", columns: categoryColumns)
            let categoryIncome = column("is_income", fallback: "0", columns: categoryColumns)
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
                    WHERE \(predicateForLiveRows(columns: categoryColumns))
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
                    isIncome: flexibleBool(row["is_income"]),
                    hidden: flexibleBool(row["hidden"]),
                    goalDefJSON: goalDefJSON,
                    source: Self.templateSource(from: row["template_settings"] as String?)
                )
                rawByGroup[groupID, default: []].append(raw)
                if let goalDefJSON {
                    let trimmed = goalDefJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != "null" {
                        goalDefsRaw[id] = trimmed
                    }
                }
            }

            let notes = try readCategoryNotes(db: db)
            var staleIDs = Set<String>()
            for stale in try staleNoteManagedTemplateCategories(
                goalDefsRaw: goalDefsRaw,
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
                            hasDefinition: hasStoredTemplateDefinition(raw.goalDefJSON),
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
}
