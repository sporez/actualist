import Foundation

/// Picker state for percentage sources. Missing entries stay in the list so a
/// saved definition can be repaired without silently rebinding it.
struct BudgetTemplatePercentageSourceOption: Equatable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isAvailable: Bool = true
}

enum BudgetTemplatePercentageSource {
    static let allIncomeID = "all income"
    static let availableFundsID = "available funds"

    static let allIncomeName = "Total of all income"
    static let availableFundsName = "Available funds to budget"
}
