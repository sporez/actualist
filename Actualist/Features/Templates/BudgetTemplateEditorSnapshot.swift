import Foundation

struct BudgetTemplateScheduleOption: Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isAvailable: Bool = true
}

struct BudgetTemplateIncomeOption: Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isAvailable: Bool = true
}

/// Loaded category templates, lock, and schedule picker options.
struct BudgetTemplateEditorSnapshot: Equatable, Sendable {
    var categoryID: String
    var categoryName: String
    var drafts: [BudgetTemplateDraft]
    var lock: BudgetTemplateCategoryLock
    var schedules: [BudgetTemplateScheduleOption]
    var incomeCategories: [BudgetTemplateIncomeOption] = []
    var currency: BudgetCurrency
    var hasDefinition: Bool
}
