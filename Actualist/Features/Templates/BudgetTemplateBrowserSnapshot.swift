import Foundation

/// One live category for the Settings Templates index and Add picker.
struct BudgetTemplateBrowserCategory: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var groupID: String
    var groupName: String
    var isIncome: Bool
    var isEffectivelyHidden: Bool
    var hasDefinition: Bool
    var drafts: [BudgetTemplateDraft]
    var lock: BudgetTemplateCategoryLock
}

/// All live categories with template metadata. Order is budget group order,
/// then category order. The Settings browser filters this into the index
/// (has `goal_def`) and the Add picker (does not).
struct BudgetTemplateBrowserSnapshot: Equatable, Sendable {
    var categories: [BudgetTemplateBrowserCategory]
    var currency: BudgetCurrency
    var month: String

    static let empty = BudgetTemplateBrowserSnapshot(
        categories: [],
        currency: .none,
        month: ""
    )
}
