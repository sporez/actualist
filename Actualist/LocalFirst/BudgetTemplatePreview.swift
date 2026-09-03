import Foundation

/// Editor / category dry-run: demand with skip-available-clamp.
struct BudgetTemplateCategoryDryRun: Equatable, Sendable {
    var budgeted: Int
    var perTemplate: [Int]
}

/// Apply confirmation preview: clamped like the write path. No budget writes.
struct BudgetTemplateApplyPreview: Equatable, Sendable {
    var assigned: Int
    var leftover: Int
    var isTrackingBudget: Bool
    var currency: BudgetCurrency
    var categories: [Category]

    struct Category: Equatable, Sendable {
        var categoryID: String
        var name: String
        var current: Int
        var proposed: Int
        var perTemplate: [Int]
        var drafts: [BudgetTemplateDraft]
    }
}
