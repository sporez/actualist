import Foundation

struct BudgetHoldTarget: Identifiable, Equatable {
    let id = UUID()
    let budgetID: String
    let month: String
    let modeIdentity: BudgetModeIdentity?
}
