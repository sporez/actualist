import Foundation

/// Whether a category's templates can be edited in Cut A.
///
/// Note-managed, unsupported types, missing columns, and stale notes all
/// lock the whole category. There is no lossless partial rewrite.
enum BudgetTemplateCategoryLock: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case missingColumns
        case noteManaged
        case staleNotes
        case unsupportedType

        /// Tester-facing copy. No schema, engine, or `#template` terms.
        var testerFacingReason: String {
            switch self {
            case .missingColumns:
                "This budget cannot store templates."
            case .noteManaged:
                "This category's templates come from the category note, so they can't be edited here."
            case .staleNotes:
                "This category's templates no longer match the category note."
            case .unsupportedType:
                "This category uses a template type that can't be edited yet."
            }
        }
    }

    case editable
    case readOnly(Reason)

    var isEditable: Bool {
        self == .editable
    }

    var testerFacingReason: String? {
        guard case .readOnly(let reason) = self else {
            return nil
        }
        return reason.testerFacingReason
    }

    /// `source` is Actual's `template_settings.source` (`ui` / `notes`) or
    /// Actualist's fixture spelling `note`. Missing source falls back to note
    /// directive presence, matching the apply stale-note guard.
    static func evaluate(
        hasGoalDefColumn: Bool,
        hasTemplateSettingsColumn: Bool,
        source: String?,
        noteHasDirectives: Bool,
        isStale: Bool,
        goalDefJSON: String?
    ) -> BudgetTemplateCategoryLock {
        if !hasGoalDefColumn || !hasTemplateSettingsColumn {
            return .readOnly(.missingColumns)
        }
        if isNoteManaged(source: source, noteHasDirectives: noteHasDirectives) {
            return .readOnly(isStale ? .staleNotes : .noteManaged)
        }
        switch BudgetTemplateDefinition.parseEntries(from: goalDefJSON) {
        case .failure:
            return .readOnly(.unsupportedType)
        case .success(let entries):
            guard BudgetTemplateDefinition.areCutAEditable(entries) else {
                return .readOnly(.unsupportedType)
            }
            return .editable
        }
    }

    static func isNoteManaged(source: String?, noteHasDirectives: Bool) -> Bool {
        let normalized = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == "ui" {
            return false
        }
        if normalized == "note" || normalized == "notes" {
            return true
        }
        return noteHasDirectives
    }
}
