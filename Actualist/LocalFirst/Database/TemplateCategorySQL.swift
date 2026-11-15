import Foundation
import GRDB

// MARK: - Note-managed template staleness guard

// Actual regenerates `categories.goal_def` from the category note's
// `#template` / `#goal` directives as a preprocessing step before applying
// templates, and clears `goal_def` when a note-managed directive is removed.
// Actualist applies CRDT-synced `goal_def` directly, so a `goal_def` can be
// stale relative to the synced note: the user edited or removed the directive
// in Actual, the new note synced, but Actual has not yet regenerated (or
// cleared) `goal_def`.
//
// This guard mirrors the *safety* half of Actual's preprocessing. Before
// applying, it refuses any note-managed `goal_def` whose source-of-truth note
// no longer matches it. UI-managed templates
// (`template_settings.source == "ui"`) are preserved untouched.
//
// The note parser (`BudgetTemplateNoteParser`) is a narrowly-scoped port of
// Actual's `template-notes.ts` / `goal-template.ts` directive grammar — enough
// to rebuild every supported `#template` / `#goal` directive's
// behaviorally-relevant fields from the note text and compare them field-by-field
// against the stored `goal_def`. It is a comparison parser only: it never
// writes `goal_def`. When the note and `goal_def` disagree (directive removed,
// type changed, any amount/field changed, or a previously-malformed line that
// is now parseable), the apply is refused with a clear error instead of
// writing stale data. `priority` is intentionally not compared: it does not
// affect a category's applied amount and Actual's note syntax does not express
// it for note-managed templates.

enum TemplateCategorySQL {
    static func templateCategoryIsIncomeByID(in database: isolated BudgetDatabase, db: Database) throws -> [String: Bool] {
        guard let columns = try categoryColumnsIfPresent(in: database, db: db) else {
            return [:]
        }
        let isIncome = database.column("is_income", fallback: "0", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(isIncome) AS is_income
                FROM categories
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                return (id, SQLiteValueCoercion.lenientBool(row["is_income"]))
            }
        )
    }

    static func readCategoryGoalDefsRaw(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard let columns = try categoryColumnsIfPresent(in: database, db: db) else {
            return [:]
        }
        guard columns.contains("goal_def") else {
            return [:]
        }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, goal_def FROM categories WHERE goal_def IS NOT NULL AND \(database.predicateForLiveRows(columns: columns))"
        )
        var result: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?,
                  let json = row["goal_def"] as String?,
                  !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            result[id] = json
        }
        return result
    }

    static func templateCategoryNames(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard let columns = try categoryColumnsIfPresent(in: database, db: db) else {
            return [:]
        }
        let name = database.column("name", fallback: "id", columns: columns)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, \(name) AS name
                FROM categories
                WHERE \(database.predicateForLiveRows(columns: columns))
                """
        )
        return Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let id = row["id"] as String? else {
                    return nil
                }
                let rawCategoryName: String? = row["name"]
                let categoryName = rawCategoryName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = categoryName.flatMap { $0.isEmpty ? nil : $0 } ?? id
                return (id, label)
            }
        )
    }

    static func templateCategoryIDsInCategoryOrder(in database: isolated BudgetDatabase, db: Database) throws -> [String] {
        guard let categoryColumns = try categoryColumnsIfPresent(in: database, db: db) else {
            return []
        }
        var order = [String]()
        if categoryColumns.contains("sort_order") {
            order.append("c.sort_order")
        }
        order.append("c.id")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id
                FROM categories c
                WHERE \(database.predicateForLiveRows(columns: categoryColumns, tableAlias: "c"))
                ORDER BY \(order.joined(separator: ", "))
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }

    static func templateCategoryIDsInBudgetOrder(
        includeIncome: Bool,
        includeHidden: Bool,
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [String] {
        guard let categoryColumns = try categoryColumnsIfPresent(in: database, db: db) else {
            return []
        }
        let groupColumn = CategoryColumns.group(in: categoryColumns)

        var predicates = [database.predicateForLiveRows(columns: categoryColumns, tableAlias: "c")]
        if !includeIncome, categoryColumns.contains("is_income") {
            predicates.append("(c.is_income = 0 OR c.is_income IS NULL)")
        }
        if !includeHidden, categoryColumns.contains("hidden") {
            predicates.append("(c.hidden = 0 OR c.hidden IS NULL)")
        }

        let groupsExist = try database.tableExists("category_groups", db: db)
        let groupColumns = groupsExist ? try database.columnSet(for: "category_groups", db: db) : []
        var join = ""
        var order: [String] = []
        if groupsExist, let groupColumn {
            if includeHidden {
                join = "LEFT JOIN category_groups g ON g.id = c.\(groupColumn)"
            } else {
                join = "INNER JOIN category_groups g ON g.id = c.\(groupColumn)"
                var visibleParts = [database.predicateForLiveRows(columns: groupColumns, tableAlias: "g")]
                if groupColumns.contains("hidden") {
                    visibleParts.append("(g.hidden = 0 OR g.hidden IS NULL)")
                }
                predicates.append(visibleParts.joined(separator: " AND "))
            }
            if groupColumns.contains("is_income") {
                order.append("g.is_income")
            }
            if groupColumns.contains("sort_order") {
                order.append("g.sort_order")
            }
            order.append("g.id")
        } else if !includeHidden {
            return []
        }
        if categoryColumns.contains("sort_order") {
            order.append("c.sort_order")
        }
        order.append("c.id")

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id
                FROM categories c
                \(join)
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY \(order.joined(separator: ", "))
                """
        )
        return rows.compactMap { $0["id"] as String? }
    }

    /// The `categories` columns, or nil when the table is missing.
    private static func categoryColumnsIfPresent(in database: isolated BudgetDatabase, db: Database) throws -> Set<String>? {
        guard try database.tableExists("categories", db: db) else { return nil }
        return try database.columnSet(for: "categories", db: db)
    }

    /// Category IDs in `goalDefsRaw` whose note-managed `goal_def` is stale
    /// relative to the current synced category note and must not be applied.
    ///
    /// UI-managed templates are never stale. Categories without a `goal_def`
    /// are never stale (there is nothing to apply).
    static func staleNoteManagedTemplateCategories(
        goalDefsRaw: [String: String],
        in database: isolated BudgetDatabase,
        db: Database
    ) throws -> [(categoryID: String, reason: String)] {
        guard !goalDefsRaw.isEmpty else { return [] }

        let notes = try readCategoryNotes(in: database, db: db)
        let sources = try readCategoryTemplateSources(in: database, db: db)

        var stale: [(String, String)] = []
        for (categoryID, json) in goalDefsRaw {
            let entries: [BudgetTemplateEntry]
            do {
                let data = Data(json.utf8)
                entries = try JSONDecoder().decode([BudgetTemplateEntry].self, from: data)
            } catch {
                // An undecodable goal_def cannot be applied safely; the main
                // apply path surfaces this separately as an unsupported
                // template. Treat it as stale-free here so the existing error
                // path owns the message.
                continue
            }

            let note = notes[categoryID] ?? ""
            let noteDirectives = BudgetTemplateNoteParser.directives(in: note)
            guard BudgetTemplateCategoryLock.isNoteManaged(
                source: sources[categoryID],
                noteHasDirectives: !noteDirectives.isEmpty
            ) else { continue }

            if let reason = BudgetTemplateNoteParser.stalenessReason(
                noteDirectives: noteDirectives,
                goalDefEntries: entries
            ) {
                stale.append((categoryID, reason))
            }
        }
        return stale
    }

    // MARK: Reads

    /// Reads category notes from Actual's generic `notes` table, keyed by the
    /// entity id (category id). Returns an empty map when the table or column
    /// is absent (older/fixture budgets).
    static func readCategoryNotes(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard try database.tableExists("notes", db: db) else { return [:] }
        let columns = try database.columnSet(for: "notes", db: db)
        guard columns.contains("note") else { return [:] }
        let idSelection = columns.contains("id") ? "id" : "NULL"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(idSelection) AS id, note
                FROM notes
                WHERE note IS NOT NULL
                """
        )
        var result: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?,
                  let note = row["note"] as String? else { continue }
            result[id] = note
        }
        return result
    }

    /// Reads `template_settings.source` per category when Actual exposes the
    /// `template_settings` JSON column on `categories`. Returns an empty map
    /// when the column is absent; callers fall back to note-directive presence
    /// to infer note-managed templates.
    private static func readCategoryTemplateSources(in database: isolated BudgetDatabase, db: Database) throws -> [String: String] {
        guard try database.tableExists("categories", db: db) else { return [:] }
        let columns = try database.columnSet(for: "categories", db: db)
        guard columns.contains("template_settings") else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, template_settings
                FROM categories
                WHERE template_settings IS NOT NULL
                """
        )
        var result: [String: String] = [:]
        for row in rows {
            guard let id = row["id"] as String?,
                  let source = TemplateAuthoringSQL.templateSource(from: row["template_settings"] as String?) else { continue }
            result[id] = source
        }
        return result
    }
}
