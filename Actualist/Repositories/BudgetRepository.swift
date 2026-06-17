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
}

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
        return try await loadBudgetMonth(
            budgetID: budgetID,
            availableMonths: availableMonths,
            monthID: monthID
        )
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        let availableMonths = try await client.budgetMonths(budgetID: budgetID)
        let monthID = availableMonths.contains(selectedMonth) ? selectedMonth : (availableMonths.last ?? selectedMonth)
        return try await loadBudgetMonth(
            budgetID: budgetID,
            availableMonths: availableMonths,
            monthID: monthID
        )
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void = {}
    ) async throws -> LoadedBudgetMonth {
        _ = try await client.updateBudgetMonthCategory(
            budgetID: budgetID,
            month: month,
            categoryID: categoryID,
            budgeted: budgeted
        )
        await didAssign()

        return try await budgetMonth(
            budgetID: budgetID,
            selectedMonth: month
        )
    }

    private func loadBudgetMonth(
        budgetID: String,
        availableMonths: [String],
        monthID: String
    ) async throws -> LoadedBudgetMonth {
        async let month = client.budgetMonth(budgetID: budgetID, month: monthID)
        async let alerts = client.budgetMonthAlerts(budgetID: budgetID, month: monthID)
        let loadedMonth = try await month
        let loadedAlerts = try await alerts

        return LoadedBudgetMonth(
            availableMonths: availableMonths,
            selectedMonth: monthID,
            month: loadedMonth,
            alerts: loadedAlerts.alerts
        )
    }
}

struct LoadedBudgetMonth: Equatable {
    let availableMonths: [String]
    let selectedMonth: String
    let month: BudgetMonth
    let alerts: [APIBudgetMonthAlert]
}

extension BudgetRepository: BudgetRepositoryProtocol {}
