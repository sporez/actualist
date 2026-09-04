import Foundation
import GRDB

extension BudgetDatabase {
    func categoryTemplateEditorSnapshot(
        categoryID: String,
        now: Date = Date()
    ) throws -> BudgetTemplateEditorSnapshot {
        let trimmed = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try queue.read { db in
            guard try tableExists("categories", db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            let columns = try columnSet(for: "categories", db: db)
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
                    WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                    LIMIT 1
                    """,
                arguments: [trimmed]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            let name = (row["name"] as String?)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let goalDefJSON = row["goal_def"] as String?
            let source = Self.templateSource(from: row["template_settings"] as String?)
            let notes = try readCategoryNotes(db: db)
            let note = notes[trimmed] ?? ""
            let noteHasDirectives = !BudgetTemplateNoteParser.directives(in: note).isEmpty
            let isStale = try isStaleNoteManagedTemplate(
                categoryID: trimmed,
                goalDefJSON: goalDefJSON,
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
            let authoringContext = try templateEditorAuthoringContext(db: db, now: now)
            let hasDefinition = hasStoredTemplateDefinition(goalDefJSON)
            return BudgetTemplateEditorSnapshot(
                categoryID: trimmed,
                categoryName: name,
                drafts: drafts,
                lock: lock,
                schedules: authoringContext.schedules,
                incomeCategories: authoringContext.incomeCategories,
                currency: try budgetCurrency(db: db),
                hasDefinition: hasDefinition
            )
        }
    }

    private func templateEditorIncomeCategories(db: Database) throws -> [BudgetTemplateIncomeOption] {
        let catalog = try templateIncomeCatalog(db: db)
        return catalog.incomeCategoryIDsInOrder.compactMap { id in
            guard let name = catalog.incomeCategoryNamesByID[id] else { return nil }
            return BudgetTemplateIncomeOption(
                id: id,
                name: name,
                isAvailable: !catalog.hiddenIncomeCategoryIDs.contains(id)
            )
        }
    }

    func templateEditorAuthoringContext(
        db: Database,
        now: Date = Date()
    ) throws -> BudgetTemplateAuthoringContext {
        BudgetTemplateAuthoringContext(
            today: now,
            schedules: try templateEditorSchedules(db: db),
            incomeCategories: try templateEditorIncomeCategories(db: db)
        )
    }

    private func templateEditorSchedules(db: Database) throws -> [BudgetTemplateScheduleOption] {
        guard try tableExists("schedules", db: db) else {
            return []
        }
        let columns = try columnSet(for: "schedules", db: db)
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
                  AND \(predicateForLiveRows(columns: columns))
                """
        )
        var options: [BudgetTemplateScheduleOption] = []
        for row in rows {
            if flexibleBool(row["completed"]) {
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
}
