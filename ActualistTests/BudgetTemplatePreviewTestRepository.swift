import Foundation
@testable import Actualist

/// Stubs for the `BudgetTemplateRepositoryProtocol` requirements a
/// template-preview fake never exercises, so each fake implements only its
/// preview calls.
protocol BudgetTemplatePreviewTestRepository: BudgetTemplateRepositoryProtocol {}

extension BudgetTemplatePreviewTestRepository {
    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        throw LocalFirstError.unsupportedWrite
    }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        throw LocalFirstError.unsupportedWrite
    }

    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot {
        throw LocalFirstError.unsupportedWrite
    }
}
