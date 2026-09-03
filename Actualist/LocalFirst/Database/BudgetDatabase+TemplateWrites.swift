import Foundation
import GRDB

extension BudgetDatabase {
    static let uiTemplateSettingsJSON = #"{"source":"ui"}"#

    /// CRDT messages that set `categories.goal_def` and
    /// `categories.template_settings.source=ui`. Empty `goalDefJSON` nulls
    /// `goal_def`. Does not apply budgets or write `cleanup_def`.
    func setCategoryTemplateMessages(
        categoryID: String,
        goalDefJSON: String?,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let trimmedID = categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing category")
        }

        return try queue.read { db in
            guard try tableExists("categories", db: db) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }
            let columns = try columnSet(for: "categories", db: db)
            guard columns.contains("goal_def"), columns.contains("template_settings") else {
                throw LocalFirstError.invalidLocalWrite(
                    BudgetTemplateCategoryLock.Reason.missingColumns.testerFacingReason
                )
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, goal_def, template_settings
                    FROM categories
                    WHERE id = ? AND \(predicateForLiveRows(columns: columns))
                    LIMIT 1
                    """,
                arguments: [trimmedID]
            ) else {
                throw LocalFirstError.invalidLocalWrite("missing category")
            }

            let currentGoalDef = row["goal_def"] as String?
            let currentSettings = row["template_settings"] as String?
            let source = Self.templateSource(from: currentSettings)
            let notes = try readCategoryNotes(db: db)
            let note = notes[trimmedID] ?? ""
            let noteHasDirectives = !BudgetTemplateNoteParser.directives(in: note).isEmpty
            let isStale = try isStaleNoteManagedTemplate(
                categoryID: trimmedID,
                goalDefJSON: currentGoalDef,
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
                throw LocalFirstError.invalidLocalWrite(reason.testerFacingReason)
            }

            let incomingJSON = normalizedGoalDefJSON(goalDefJSON)
            switch BudgetTemplateDefinition.parseEntries(from: incomingJSON) {
            case .failure:
                throw LocalFirstError.invalidLocalWrite(
                    BudgetTemplateCategoryLock.Reason.unsupportedType.testerFacingReason
                )
            case .success(let entries):
                guard BudgetTemplateDefinition.areCutAEditable(entries) else {
                    throw LocalFirstError.invalidLocalWrite(
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
                        value: .string(Self.uiTemplateSettingsJSON)
                    )
                )
            }
            return messages
        }
    }
}

extension BudgetDatabase {
    func isStaleNoteManagedTemplate(
        categoryID: String,
        goalDefJSON: String?,
        db: Database
    ) throws -> Bool {
        guard let goalDefJSON else {
            return false
        }
        let trimmed = goalDefJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else {
            return false
        }
        let stale = try staleNoteManagedTemplateCategories(
            goalDefsRaw: [categoryID: trimmed],
            db: db
        )
        return stale.contains { $0.categoryID == categoryID }
    }

    fileprivate func normalizedGoalDefJSON(_ json: String?) -> String? {
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

    fileprivate func goalDefUnchanged(current: String?, incoming: String?) -> Bool {
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
