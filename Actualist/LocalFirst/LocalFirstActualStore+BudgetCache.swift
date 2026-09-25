import Foundation

extension LocalFirstActualStore {
    /// Recompute the selected month even for backdated writes; its balance may
    /// depend on any earlier rollover month. External reads do not change selection.
    func reloadSelectedBudgetCache(budgetID: String, now: Date = Date()) async throws {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        budgetReadGeneration &+= 1
        monthsByBudget[budgetID] = nil
        templateBrowserByBudget[budgetID] = nil
        let prefix = "\(budgetID)|"
        // Open feeds observe these snapshots directly. Replace their contents
        // after a write instead of evicting them until the screen is reopened.
        for key in Array(categoryTransactionsByKey.keys) where key.hasPrefix(prefix) {
            let scope = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 1)
            guard scope.count == 2 else { continue }
            try await refreshCategoryTransactions(
                budgetID: budgetID, categoryID: String(scope[0]), month: String(scope[1])
            )
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        }
        for key in Array(uncategorizedTransactionsByKey.keys) where key.hasPrefix(prefix) {
            _ = try await uncategorizedTransactions(budgetID: budgetID, month: String(key.dropFirst(prefix.count)))
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        }
        guard let selected = loadedBudgetMonthsByBudget[budgetID]?.selectedMonth else { return }
        let loaded = try await readBudgetMonth(budgetID: budgetID, month: selected, now: now)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        guard loadedBudgetMonthsByBudget[budgetID]?.selectedMonth == selected else { return }
        loadedBudgetMonthsByBudget[budgetID] = loaded
        currencyByBudget[budgetID] = loaded.currency
    }
}
