import Foundation

/// Local database incarnation plus Actual's authoritative budget-type revision.
/// A round trip through another mode changes revision even when the table matches.
struct BudgetModeIdentity: Codable, Equatable, Hashable, Sendable {
    let storageID: String
    let table: BudgetTable
    let revision: String?
}

enum BudgetModeWriteError: LocalizedError, Equatable {
    case budgetChanged
    case unsupportedAction

    var errorDescription: String? {
        switch self {
        case .budgetChanged:
            "The budget type changed. Start a new edit to use the current budget."
        case .unsupportedAction:
            "This action is not available for tracking budgets."
        }
    }
}
