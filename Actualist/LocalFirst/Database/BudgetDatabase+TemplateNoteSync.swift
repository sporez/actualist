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

extension BudgetDatabase {
    /// Category IDs in `goalDefsRaw` whose note-managed `goal_def` is stale
    /// relative to the current synced category note and must not be applied.
    ///
    /// UI-managed templates are never stale. Categories without a `goal_def`
    /// are never stale (there is nothing to apply).
    func staleNoteManagedTemplateCategories(
        goalDefsRaw: [String: String],
        db: Database
    ) throws -> [(categoryID: String, reason: String)] {
        guard !goalDefsRaw.isEmpty else { return [] }

        let notes = try readCategoryNotes(db: db)
        let sources = try readCategoryTemplateSources(db: db)

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
    func readCategoryNotes(db: Database) throws -> [String: String] {
        guard try tableExists("notes", db: db) else { return [:] }
        let columns = try columnSet(for: "notes", db: db)
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
    func readCategoryTemplateSources(db: Database) throws -> [String: String] {
        guard try tableExists("categories", db: db) else { return [:] }
        let columns = try columnSet(for: "categories", db: db)
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
                  let source = Self.templateSource(from: row["template_settings"] as String?) else { continue }
            result[id] = source
        }
        return result
    }
}
