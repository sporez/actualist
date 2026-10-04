import Foundation

extension BudgetViewModel {
    func refreshSelectedMonth(using appState: AppState) async {
        includeCarryoverCategoriesInOverspentAlerts =
            appState.settings.includeCarryoverCategoriesInOverspentAlerts
        guard let budgetID = appState.settings.selectedBudgetID else {
            if selectedMonth == nil { isLoading = false }
            return
        }
        await refreshSelectedMonth(budgetID: budgetID, repository: appState.budgetRepository)
    }

    /// Re-reads the selected month (or the current month before one exists).
    /// Overlapping calls for the same budget share one load.
    func refreshSelectedMonth(budgetID: String, repository: any BudgetRepositoryProtocol) async {
        await refreshCoalescer.run(budgetID: budgetID) { [self] in
            if let selectedMonth {
                await selectMonth(selectedMonth, budgetID: budgetID, repository: repository)
            } else {
                await load(budgetID: budgetID, repository: repository)
            }
        }
    }
}
