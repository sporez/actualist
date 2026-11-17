import Foundation

/// Template authoring: the editor, browser and dry-run reads, the template
/// write, and the Apply Templates previews.
protocol BudgetTemplateRepositoryProtocol: Sendable {
    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun
    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot
    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot
    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview
    /// `excluding` holds the categories the review has skipped; each mode
    /// applies only the ones it lists (see `BudgetTemplateApplyPreview`).
    func previewBudgetTemplatePair(
        budgetID: String,
        month: String,
        excluding: Set<String>
    ) async throws -> BudgetTemplateApplyPreviewPair
}
