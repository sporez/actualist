import Foundation

struct BudgetRepository: Sendable {
    let client: ActualAPIClient

    func budgets() async throws -> [ActualBudget] {
        try await client.budgets()
    }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        let availableMonths = try await client.budgetMonths(budgetID: budgetID)
        let monthID = availableMonths.contains(preferredMonth) ? preferredMonth : (availableMonths.last ?? preferredMonth)
        let month = try await client.budgetMonth(budgetID: budgetID, month: monthID)
        return LoadedBudgetMonth(
            availableMonths: availableMonths,
            selectedMonth: monthID,
            month: month
        )
    }
}

struct LoadedBudgetMonth: Equatable {
    let availableMonths: [String]
    let selectedMonth: String
    let month: BudgetMonth
}
