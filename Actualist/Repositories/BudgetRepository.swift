import Foundation

protocol BudgetRepositoryProtocol: Sendable {
    func budgets() async throws -> [ActualBudget]
    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth
    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth
    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
}

struct LoadedBudgetMonth: Equatable {
    let availableMonths: [String]
    let selectedMonth: String
    let month: BudgetMonth
    let alerts: [APIBudgetMonthAlert]
}

struct BudgetMoveMoneyCommand: Hashable, Sendable {
    let fromCategoryID: String?
    let toCategoryID: String?
    let amount: Int
}
